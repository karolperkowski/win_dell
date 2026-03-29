#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy tray notification - fires once after deployment tasks are gone.

.DESCRIPTION
    Runs at every logon via the WinDeploy-Notify scheduled task.

    Decision tree:
      WinDeploy-Resume task still exists?  → exit silently (deployment running, monitor handles UI)
      No state.json?                        → exit silently (WinDeploy never ran on this machine)
      DeployComplete = true                 → show SUCCESS balloon, remove self
      DeployComplete = false                → show WARNING balloon (interrupted), remove self

    After showing, unregisters WinDeploy-Notify so it never fires again.
    No dependencies beyond what ships with Windows.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
$ConfirmPreference     = 'None'

# ---------------------------------------------------------------------------
# Early logger - writes to disk before any Import-Module so startup
# failures are always captured even if the logging module cannot load.
# ---------------------------------------------------------------------------
$Script:_rawLog = 'C:\ProgramData\WinDeploy\Logs\early.log'
function Write-Early {
    param([string]$Msg)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Msg"
    Write-Host $line
    try {
        $dir = Split-Path $Script:_rawLog
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        Add-Content -Path $Script:_rawLog -Value $line -Encoding UTF8
    } catch { Write-Host "[Notify] Log write failed: $($_.Exception.Message)" }
}
Write-Early "=== $(Split-Path -Leaf $MyInvocation.MyCommand.Path) started (PID $PID) ==="
Write-Early "PSScriptRoot : $PSScriptRoot"
Write-Early "Running as   : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Early "ExecutionPolicy: $(Get-ExecutionPolicy)"
   # Notification failures must not be visible to user

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$DEPLOY_ROOT   = 'C:\ProgramData\WinDeploy'
$STATE_FILE    = Join-Path $DEPLOY_ROOT 'state.json'
$LOG_DIR       = Join-Path $DEPLOY_ROOT 'Logs'
$RESUME_TASK   = 'WinDeploy-Resume'
$NOTIFY_TASK   = 'WinDeploy-Notify'
$AUTO_CLOSE_MS = 20000   # balloon auto-dismisses after 20 s

# ---------------------------------------------------------------------------
# Guard: deployment still running → nothing to do
# ---------------------------------------------------------------------------
$resumeTask = Get-ScheduledTask -TaskName $RESUME_TASK -ErrorAction SilentlyContinue
if ($resumeTask) { exit 0 }

# Guard: WinDeploy never ran on this machine
if (-not (Test-Path $STATE_FILE)) { exit 0 }

# ---------------------------------------------------------------------------
# Read state
# ---------------------------------------------------------------------------
try {
    $state = Get-Content $STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
} catch { exit 0 }

# ---------------------------------------------------------------------------
# Build notification content
# ---------------------------------------------------------------------------
if ($state.DeployComplete -eq $true) {
    $balloonTitle   = 'WinDeploy — Deployment complete'
    $elapsed = try {
        $span = [datetime]::Parse($state.DeployCompletedAt) - [datetime]::Parse($state.BootstrappedAt)
        "$([int]$span.TotalMinutes) min"
    } catch { 'unknown duration' }
    $balloonText    = "All stages finished successfully in $elapsed. Reboots: $($state.RebootCount)."
    $balloonIcon    = [System.Windows.Forms.ToolTipIcon]::Info
    $trayIcon       = [System.Drawing.SystemIcons]::Information
    $menuTitle      = 'Deployment complete'
} else {
    $balloonTitle   = 'WinDeploy — Deployment interrupted'
    $lastErr        = if ($state.LastError) { $state.LastError } else { 'Unknown error' }
    $balloonText    = "Last stage: $($state.CurrentStage). Error: $lastErr"
    $balloonIcon    = [System.Windows.Forms.ToolTipIcon]::Warning
    $trayIcon       = [System.Drawing.SystemIcons]::Warning
    $menuTitle      = 'Deployment interrupted'
}

# ---------------------------------------------------------------------------
# Build tray icon + context menu
# ---------------------------------------------------------------------------
$notify = [System.Windows.Forms.NotifyIcon]::new()
$notify.Icon    = $trayIcon
$notify.Visible = $true
$notify.Text    = 'WinDeploy'   # tooltip on hover

$menu = [System.Windows.Forms.ContextMenuStrip]::new()

# Menu header (greyed-out title)
$headerItem = [System.Windows.Forms.ToolStripMenuItem]::new($menuTitle)
$headerItem.Enabled = $false
$menu.Items.Add($headerItem) | Out-Null
$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

# Open logs folder
$logsItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open deployment logs')
$logsItem.Add_Click({
    if (Test-Path $LOG_DIR) {
        Start-Process explorer.exe $LOG_DIR
    }
})
$menu.Items.Add($logsItem) | Out-Null

# Open state file
$stateItem = [System.Windows.Forms.ToolStripMenuItem]::new('View state.json')
$stateItem.Add_Click({
    if (Test-Path $STATE_FILE) {
        Start-Process notepad.exe $STATE_FILE
    }
})
$menu.Items.Add($stateItem) | Out-Null

$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

# Dismiss
$dismissItem = [System.Windows.Forms.ToolStripMenuItem]::new('Dismiss')
$dismissItem.Add_Click({ $script:AppContext.ExitThread() })
$menu.Items.Add($dismissItem) | Out-Null

$notify.ContextMenuStrip = $menu

# Clicking the tray icon itself also dismisses
$notify.Add_Click({ $script:AppContext.ExitThread() })
$notify.Add_BalloonTipClicked({ $script:AppContext.ExitThread() })
$notify.Add_BalloonTipClosed({ $script:AppContext.ExitThread() })

# ---------------------------------------------------------------------------
# Auto-close timer
# ---------------------------------------------------------------------------
$autoClose = [System.Windows.Forms.Timer]::new()
$autoClose.Interval = $AUTO_CLOSE_MS
$autoClose.Add_Tick({ $script:AppContext.ExitThread() })
$autoClose.Start()

# ---------------------------------------------------------------------------
# Show balloon
# ---------------------------------------------------------------------------
$notify.BalloonTipTitle = $balloonTitle
$notify.BalloonTipText  = $balloonText
$notify.BalloonTipIcon  = $balloonIcon
$notify.ShowBalloonTip($AUTO_CLOSE_MS)

# ---------------------------------------------------------------------------
# Run message loop (required for tray icon to be interactive)
# ---------------------------------------------------------------------------
$script:AppContext = [System.Windows.Forms.ApplicationContext]::new()
[System.Windows.Forms.Application]::Run($script:AppContext)

# ---------------------------------------------------------------------------
# Cleanup: hide icon, unregister this task so it never fires again
# ---------------------------------------------------------------------------
$autoClose.Stop()
$autoClose.Dispose()
$notify.Visible = $false
$notify.Dispose()
$menu.Dispose()

Unregister-ScheduledTask -TaskName $NOTIFY_TASK -Confirm:$false -ErrorAction SilentlyContinue
