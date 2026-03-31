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
# TUI Drawing
# ---------------------------------------------------------------------------
function Write-Color {
    param([string]$Text, [ConsoleColor]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color -NoNewline
}

function Get-ConsoleWidth {
    try { return [Math]::Max(80, [Console]::WindowWidth) } catch { return 80 }
}

function Write-Line {
    param([string]$Text = '', [ConsoleColor]$Color = 'Gray')
    # Pad to console width to clear previous content
    $width = Get-ConsoleWidth
    Write-Host ($Text.PadRight($width)) -ForegroundColor $Color
}

function Draw-Screen {
    $state = Read-StateFile
    $ts    = Read-TailscaleJson

    # Position cursor at top — graceful fallback for non-interactive shells
    try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
    try { [Console]::CursorVisible = $false } catch {}

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

    # Elapsed
    $elapsed = '--:--:--'
    $bootAt  = Get-StateProp $state 'BootstrappedAt' ''
    if ($bootAt) {
        try {
            $span = (Get-Date) - [datetime]$bootAt
            $elapsed = '{0:d2}:{1:d2}:{2:d2}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds
        } catch {}
    }

    # ── Header ──
    Write-Line ''
    if ($complete) {
        Write-Line '  WINDEPLOY - Deployment complete' Green
    } else {
        Write-Line '  WINDEPLOY - Deployment in progress' Cyan
    }
    $hostname = $env:COMPUTERNAME
    Write-Line "  $hostname" DarkGray
    Write-Line ''

    # ── Metrics ──
    $pct = if ($nTotal -gt 0) { [Math]::Round(($nComplete / $nTotal) * 100) } else { 0 }
    Write-Color '  Elapsed: ' DarkGray; Write-Color $elapsed White
    Write-Color '    Reboots: ' DarkGray; Write-Color "$reboots" White
    Write-Color '    Stage: ' DarkGray; Write-Color "$nComplete / $nTotal" White
    Write-Color '    ' DarkGray; Write-Color "($pct%)" Cyan
    Write-Host ''
    Write-Line ''

    # ── Progress bar ──
    $barWidth = [Math]::Max(40, (Get-ConsoleWidth) - 8)
    $filled   = [Math]::Floor($barWidth * $pct / 100)
    $empty    = $barWidth - $filled
    Write-Color '  ' DarkGray
    Write-Color ([string]::new([char]0x2588, $filled)) Cyan
    Write-Color ([string]::new([char]0x2591, $empty)) DarkGray
    Write-Host ''
    Write-Line ''

    # ── Stages ──
    Write-Line '  STAGES' DarkGray
    Write-Line ('  ' + [string]::new('-', 50)) DarkGray

    foreach ($stageName in $STAGE_ORDER) {
        $label = Get-StageLabel $stageName
        $padded = $label.PadRight(28)

        if ($stageName -in $completed) {
            $icon = [char]0x2713  # checkmark
            $timeStr = ''
            if ($timestamps -and $timestamps.PSObject -and $timestamps.PSObject.Properties[$stageName]) {
                try { $timeStr = ([datetime]$timestamps.$stageName).ToString('HH:mm:ss') } catch {}
            }
            Write-Color "  $icon " Green
            Write-Color $padded Green
            Write-Line $timeStr DarkGray
        } elseif ($stageName -in $failed) {
            $icon = [char]0x2717  # x mark
            Write-Color "  $icon " Red
            Write-Line $padded Red
        } elseif ($stageName -eq $current -and -not $complete) {
            $icon = [char]0x25B6  # play
            Write-Color "  $icon " Yellow
            Write-Color $padded Yellow
            Write-Line 'Running...' Yellow
        } else {
            $icon = [char]0x2013  # dash
            Write-Color "  $icon " DarkGray
            Write-Line $padded DarkGray
        }
    }

    Write-Line ''

    # ── Tailscale auth URL ──
    $showTs = ($current -eq 'InstallTailscale') -or ($ts -and $ts.AuthUrl -and -not $ts.Registered)
    if ($showTs -and $ts -and $ts.AuthUrl) {
        Write-Line '  TAILSCALE AUTH' Cyan
        Write-Line ('  ' + [string]::new('-', 50)) DarkGray
        if ($ts.Registered) {
            Write-Color '  Registered as: ' Green
            Write-Line "$($ts.MachineName)" Green
        } else {
            Write-Line '  Scan this URL or open it in a browser:' DarkGray
            Write-Line "  $($ts.AuthUrl)" White
            Write-Line '  Waiting for scan...' Yellow
        }
        Write-Line ''
    }

    # ── Error ──
    if ($lastErr) {
        Write-Line '  LAST ERROR' Red
        Write-Line ('  ' + [string]::new('-', 50)) DarkGray
        Write-Line "  Stage: $lastErrStg" Red
        Write-Line "  $lastErr" Red
        Write-Line ''
    }

    # ── Recent activity ──
    Write-Line '  RECENT ACTIVITY' DarkGray
    Write-Line ('  ' + [string]::new('-', 50)) DarkGray

    $logLines = Get-SessionLogTail -Lines 8
    foreach ($line in $logLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '\[SUCCESS\]') {
            Write-Line "  $trimmed" Green
        } elseif ($trimmed -match '\[ERROR\]') {
            Write-Line "  $trimmed" Red
        } elseif ($trimmed -match '\[WARN\]') {
            Write-Line "  $trimmed" Yellow
        } elseif ($trimmed -match '\[SECTION\]') {
            Write-Line "  $trimmed" Cyan
        } else {
            Write-Line "  $trimmed" DarkGray
        }
    }

    # Pad remaining lines to clear old content
    $usedRows = 12 + $STAGE_ORDER.Count + $logLines.Count + $(if ($showTs) { 5 } else { 0 }) + $(if ($lastErr) { 5 } else { 0 })
    $consoleHeight = try { [Math]::Max(30, [Console]::WindowHeight) } catch { 30 }
    $remaining = $consoleHeight - $usedRows - 2
    for ($i = 0; $i -lt $remaining; $i++) { Write-Line '' }

    # ── Footer ──
    $now = Get-Date -Format 'HH:mm:ss'
    if ($complete) {
        Write-Line "  Updated $now  |  Deployment complete  |  Closing in $Script:closeCountdown s" Green
    } else {
        Write-Line "  Updated $now  |  Refreshing every ${REFRESH_SEC}s  |  Ctrl+C to hide" DarkGray
    }

    return $complete
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$Host.UI.RawUI.WindowTitle = 'WinDeploy Monitor'

# Set console size for a good TUI experience
try {
    if ([Console]::WindowWidth -lt 90) { [Console]::WindowWidth = 100 }
    if ([Console]::WindowHeight -lt 35) { [Console]::WindowHeight = 40 }
    [Console]::BufferWidth  = [Math]::Max([Console]::BufferWidth, [Console]::WindowWidth)
    [Console]::BufferHeight = [Math]::Max([Console]::BufferHeight, [Console]::WindowHeight)
} catch {}

# Clear screen once at start
try { [Console]::Clear() } catch { Clear-Host }

$Script:closeCountdown = $CLOSE_DELAY

try {
    while ($true) {
        try {
            $done = Draw-Screen
        } catch {
            Append-Log $Script:_crashLog ("[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] Draw error: $($_.Exception.Message)`r`n")
        }

        if ($done) {
            $Script:closeCountdown -= $REFRESH_SEC
            if ($Script:closeCountdown -le 0) {
                Write-Line ''
                Write-Line '  Monitor closing. Deployment is complete.' Green
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
