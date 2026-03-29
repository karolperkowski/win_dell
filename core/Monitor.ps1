#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Monitor - Live deployment progress window.

.DESCRIPTION
    Launched at logon by the WinDeploy-Monitor scheduled task.
    Polls state.json every 3 seconds. Shows stage status, metrics, live log tail.
    When InstallTailscale is the current stage, displays the QR code and auth URL
    so the machine can be registered without a keyboard.
    Auto-closes 60 seconds after DeployComplete = true. A Close button appears on completion.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

# ---------------------------------------------------------------------------
# Early logger - writes to disk before any Import-Module so startup
# failures are always captured even if the logging module cannot load.
# ---------------------------------------------------------------------------
$Script:_rawLog = 'C:\ProgramData\WinDeploy\Logs\early.log'
$Script:_crashLog = 'C:\ProgramData\WinDeploy\Logs\monitor_crash.log'

# Append text to a log file allowing concurrent writers.
# [System.IO.File]::AppendAllText uses FileShare.Read which blocks when
# another process has the file open. FileStream with FileShare.ReadWrite
# allows the Orchestrator (SYSTEM) and Monitor (user) to write simultaneously.
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
    Write-Host $line
    try {
        Append-Log $Script:_rawLog "$line`r`n"
    } catch { Write-Host "[Monitor] Log write failed: $_" }
}

# Resolve script directory regardless of how the script was launched.
# $PSScriptRoot is empty when launched via Start-Process -ArgumentList,
# so fall back to $MyInvocation.MyCommand.Path.
$Script:_scriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path $MyInvocation.MyCommand.Path -Parent
} else {
    'C:\ProgramData\WinDeploy\repo\core'
}

Write-Early "=== Monitor.ps1 started (PID $PID) ==="
Write-Early "ScriptDir    : $Script:_scriptDir"
Write-Early "PSScriptRoot : $PSScriptRoot"
Write-Early "Running as   : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Early "ExecutionPolicy: $(Get-ExecutionPolicy)"


# Load shared constants - provides Get-WDConfig for DeployRoot, StageOrder, etc.
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
$STAGE_ORDER  = if ($Script:_wd) { @($Script:_wd.StageOrder) } else { @('WindowsUpdate','PowerSettings','Debloat','WinTweaks','InstallDellSupportAssist','InstallDellPowerManager','InstallTailscale','Cleanup') }
$STAGE_LABELS = if ($Script:_wd) { $Script:_wd.StageLabels   } else { @{} }
$REFRESH_MS   = 3000
$CLOSE_DELAY  = 60



Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Keep display and system awake while the monitor is open.
# ES_CONTINUOUS(0x80000000) | ES_DISPLAY_REQUIRED(0x00000002) | ES_SYSTEM_REQUIRED(0x00000001)
# Use Convert::ToUInt32 from hex string - [uint32]0x80000000 still overflows because PS 5.1
# parses the literal as Int32 (-2147483648) before the cast, which then fails on uint.
try {
    Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' `
             -Name 'SleepGuard' -Namespace 'WinDeploy' -ErrorAction Stop
    # Use Convert::ToUInt32 to parse hex - avoids PS 5.1 Int32 literal overflow on 0x80000000
    $esFlags = [System.Convert]::ToUInt32('80000003', 16)
    [WinDeploy.SleepGuard]::SetThreadExecutionState($esFlags) | Out-Null
} catch { Append-Log $Script:_rawLog ("[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [WARN] SleepGuard failed: $($_.Exception.Message)" + "`r`n") }

# ---------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WinDeploy Monitor" Width="640" Height="760"
    ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
    Background="#0F0F0F" Foreground="#E0E0E0" FontFamily="Segoe UI">
  <ScrollViewer VerticalScrollBarVisibility="Auto">
    <Grid Margin="20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Header -->
      <Grid Grid.Row="0" Margin="0,0,0,16">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock x:Name="TitleLabel" Text="Deployment in progress" FontSize="17" FontWeight="Medium" Foreground="#E0E0E0"/>
          <TextBlock x:Name="SubtitleLabel" Text="Initialising..." FontSize="12" Foreground="#555555" Margin="0,3,0,0"/>
          <TextBlock x:Name="VersionLabel" Text="" FontSize="10" Foreground="#336699"
                     Cursor="Hand" TextDecorations="Underline" Margin="0,3,0,0"
                     ToolTip="Open this commit on GitHub"/>
        </StackPanel>
        <Border Grid.Column="1" x:Name="StatusBorder" Background="#0E1520" BorderBrush="#1A3050"
                BorderThickness="1" CornerRadius="4" Padding="10,5" VerticalAlignment="Center">
          <TextBlock x:Name="StatusBadge" Text="Starting..." FontSize="12" Foreground="#60A5FA"/>
        </Border>
      </Grid>

      <!-- Metrics -->
      <Grid Grid.Row="1" Margin="0,0,0,16">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Background="#1A1A1A" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="0,0,6,0">
          <StackPanel>
            <TextBlock Text="ELAPSED" FontSize="10" Foreground="#555555"/>
            <TextBlock x:Name="ElapsedLabel" Text="00:00:00" FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0" FontFamily="Consolas"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="1" Background="#1A1A1A" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="3,0,3,0">
          <StackPanel>
            <TextBlock Text="REBOOTS" FontSize="10" Foreground="#555555"/>
            <TextBlock x:Name="RebootLabel" Text="0" FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0" FontFamily="Consolas"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" Background="#1A1A1A" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="6,0,0,0">
          <StackPanel>
            <TextBlock Text="STAGE" FontSize="10" Foreground="#555555"/>
            <TextBlock x:Name="StageCountLabel" Text="- / -" FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0" FontFamily="Consolas"/>
          </StackPanel>
        </Border>
      </Grid>

      <!-- Progress bar -->
      <Grid Grid.Row="2" Margin="0,0,0,18">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid Margin="0,0,0,6">
          <TextBlock Text="Overall progress" FontSize="11" Foreground="#555555"/>
          <TextBlock x:Name="PctLabel" Text="0%" FontSize="11" Foreground="#378ADD" HorizontalAlignment="Right"/>
        </Grid>
        <Border Grid.Row="1" Background="#1E1E1E" CornerRadius="2" Height="5">
          <Border x:Name="ProgressFill" Background="#378ADD" CornerRadius="2" HorizontalAlignment="Left" Width="0"/>
        </Border>
      </Grid>

      <!-- Stages label -->
      <TextBlock Grid.Row="3" Text="STAGES" FontSize="10" Foreground="#444444" Margin="0,0,0,8"/>

      <!-- Stages list -->
      <StackPanel Grid.Row="4" x:Name="StagesPanel" Margin="0,0,0,16"/>

      <!-- Tailscale QR panel -->
      <Border Grid.Row="5" x:Name="TailscalePanel" Visibility="Collapsed"
              Background="#080E18" BorderBrush="#1A3050" BorderThickness="1"
              CornerRadius="6" Margin="0,0,0,16">
        <Grid Margin="16,14">
          <Grid.ColumnDefinitions><ColumnDefinition Width="148"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Background="#FFFFFF" CornerRadius="4" Width="136" Height="136" VerticalAlignment="Top" HorizontalAlignment="Left">
            <Image x:Name="QrImage" Width="124" Height="124" Stretch="Uniform" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="16,2,0,0" VerticalAlignment="Center">
            <TextBlock Text="TAILSCALE REGISTRATION" FontSize="10" Foreground="#2A4870" Margin="0,0,0,8"/>
            <TextBlock Text="Scan with the Tailscale app to register this machine."
                       FontSize="12" Foreground="#506080" TextWrapping="Wrap" Margin="0,0,0,10"/>
            <TextBlock x:Name="TailscaleUrlText" Text="" FontSize="10"
                       Foreground="#3080C0" FontFamily="Consolas" TextWrapping="Wrap" Margin="0,0,0,10"/>
            <Border x:Name="TailscaleStatusBorder" Background="#0E1520" BorderBrush="#1A3050"
                    BorderThickness="1" CornerRadius="4" Padding="8,5" HorizontalAlignment="Left">
              <TextBlock x:Name="TailscaleStatusText" Text="Waiting for scan..." FontSize="11" Foreground="#60A5FA"/>
            </Border>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Log -->
      <TextBlock Grid.Row="6" Text="RECENT ACTIVITY" FontSize="10" Foreground="#444444" Margin="0,0,0,8"/>
      <Border Grid.Row="7" Background="#0A0A0A" BorderBrush="#1E1E1E" BorderThickness="1" CornerRadius="5" Padding="12,10" Height="100">
        <StackPanel x:Name="LogPanel"/>
      </Border>

      <!-- Footer -->
      <Grid Grid.Row="8" Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="FooterNote" Text="" FontSize="10" Foreground="#333333"
                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <TextBlock x:Name="CloseCountdown" Text="" FontSize="10" Foreground="#555555"
                     VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button x:Name="CloseBtn" Content="✕ Close" FontSize="10" Padding="8,3"
                  Background="#1A2030" Foreground="#4ADE80" BorderBrush="#2D4A2D"
                  Cursor="Hand" Visibility="Collapsed" ToolTip="Close the monitor window" Margin="0,0,8,0"/>
          <Button x:Name="RunNowBtn" Content="▶ Run Now" FontSize="10" Padding="8,3"
                  Background="#1A2030" Foreground="#60A5FA" BorderBrush="#1A3050"
                  Cursor="Hand" ToolTip="Start the orchestrator immediately without waiting for a reboot"/>
        </StackPanel>
      </Grid>

      <!-- Error panel: visible on any error, stays open, never auto-dismisses -->
      <Border Grid.Row="9" x:Name="ErrorPanel" Visibility="Collapsed"
              Background="#1F0E0E" BorderBrush="#5A2020" BorderThickness="1"
              CornerRadius="5" Margin="0,8,0,0" Padding="12,10">
        <StackPanel>
          <TextBlock Text="MONITOR ERROR" FontSize="10" Foreground="#7A2020"
                     FontFamily="Segoe UI" Margin="0,0,0,6"/>
          <TextBlock x:Name="ErrorText" Text="" FontSize="11" Foreground="#F87171"
                     FontFamily="Consolas" TextWrapping="Wrap"/>
          <TextBlock x:Name="ErrorLogPath" Text="" FontSize="10" Foreground="#555555"
                     FontFamily="Consolas" Margin="0,6,0,0"/>
        </StackPanel>
      </Border>

    </Grid>
  </ScrollViewer>
</Window>
'@

try {
    $reader = [System.Xml.XmlNodeReader]::new($XAML)
    $Window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    $msg = "FATAL: XamlReader.Load failed - $($_.Exception.Message)"
    Write-Early $msg
    try { Append-Log $Script:_crashLog (($msg) + "`r`n") } catch {}
    try {
        [System.IO.File]::WriteAllText(
            'C:\ProgramData\WinDeploy\Logs\monitor_crash.txt',
            "WinDeploy Monitor - XAML Load Failed`r`n`r`n$($_.Exception.Message)`r`n`r`nCheck: $Script:_rawLog"
        )
    } catch {}
    # Show a plain Windows message box - no WPF needed
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "WinDeploy Monitor failed to start:`n`n$($_.Exception.Message)`n`nCheck: C:\ProgramData\WinDeploy\Logs\early.log",
        'WinDeploy Monitor', 'OK', 'Error') | Out-Null
    exit 1
}

$TitleLabel           = $Window.FindName('TitleLabel')
$SubtitleLabel        = $Window.FindName('SubtitleLabel')
$VersionLabel         = $Window.FindName('VersionLabel')
$StatusBadge          = $Window.FindName('StatusBadge')
$StatusBorder         = $Window.FindName('StatusBorder')
$ElapsedLabel         = $Window.FindName('ElapsedLabel')
$RebootLabel          = $Window.FindName('RebootLabel')
$StageCountLabel      = $Window.FindName('StageCountLabel')
$PctLabel             = $Window.FindName('PctLabel')
$ProgressFill         = $Window.FindName('ProgressFill')
$StagesPanel          = $Window.FindName('StagesPanel')
$TailscalePanel       = $Window.FindName('TailscalePanel')
$QrImage              = $Window.FindName('QrImage')
$TailscaleUrlText     = $Window.FindName('TailscaleUrlText')
$TailscaleStatusText  = $Window.FindName('TailscaleStatusText')
$TailscaleStatusBorder= $Window.FindName('TailscaleStatusBorder')
$LogPanel             = $Window.FindName('LogPanel')
$FooterNote           = $Window.FindName('FooterNote')
$CloseCountdown       = $Window.FindName('CloseCountdown')
$CloseBtn             = $Window.FindName('CloseBtn')
$RunNowBtn            = $Window.FindName('RunNowBtn')
$ErrorPanel           = $Window.FindName('ErrorPanel')
$ErrorText            = $Window.FindName('ErrorText')
$ErrorLogPath         = $Window.FindName('ErrorLogPath')

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$Window.Left = $screen.Right  - $Window.Width  - 20
$Window.Top  = $screen.Bottom - $Window.Height - 20

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Read-JsonFile ($Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-StateProp {
    # Safe property access on state object - returns $default if property missing.
    # Prevents "property cannot be found" errors when reading a partial state file
    # written by bootstrap before the orchestrator has fully initialised it.
    param($State, [string]$Name, $Default = $null)
    if ($null -eq $State) { return $Default }
    $val = $State.PSObject.Properties[$Name]
    if ($null -eq $val) { return $Default }
    $v = $val.Value
    if ($null -eq $v) { return $Default }
    return $v
}


function Format-Elapsed ($Iso) {
    try { $s = (Get-Date) - [datetime]::Parse($Iso); return '{0:D2}:{1:D2}:{2:D2}' -f [int]$s.TotalHours, $s.Minutes, $s.Seconds }
    catch { return '--:--:--' }
}

function Get-StageStatus ($State, $Name) {
    if (-not $State) { return 'waiting' }
    if (@(Get-StateProp $State 'CompletedStages' @()) -contains $Name) { return 'complete' }
    if (@(Get-StateProp $State 'FailedStages'    @()) -contains $Name) { return 'failed' }
    if ((Get-StateProp $State 'CurrentStage' '') -eq $Name -and
        -not (Get-StateProp $State 'DeployComplete' $false))            { return 'running' }
    return 'waiting'
}

function New-Brush ($Hex) { [System.Windows.Media.BrushConverter]::new().ConvertFrom($Hex) }
function New-Thickness ($All) { [System.Windows.Thickness]::new($All) }

function Add-StageRow ($Label, $Status, $Time) {
    $colours = switch ($Status) {
        'complete' { @{ bg='#0E1A0E'; border='#1D3A1D'; icon=[char]0x2713; ic='#4ADE80'; name='#CCCCCC'; time='#4ADE80' } }
        'running'  { @{ bg='#0E1520'; border='#1A3050'; icon=[char]0x25B6; ic='#60A5FA'; name='#E0E0E0'; time='#60A5FA' } }
        'failed'   { @{ bg='#1F0E0E'; border='#3D1A1A'; icon=[char]0x2717; ic='#F87171'; name='#F87171'; time='#F87171' } }
        default    { @{ bg='#131313'; border='#1E1E1E'; icon=[char]0x2013; ic='#444444'; name='#444444'; time='#444444' } }
    }

    $border = [System.Windows.Controls.Border]@{
        Background      = New-Brush $colours.bg
        BorderBrush     = New-Brush $colours.border
        BorderThickness = New-Thickness 1
        CornerRadius    = [System.Windows.CornerRadius]::new(5)
        Padding         = [System.Windows.Thickness]::new(12,9,12,9)
        Margin          = [System.Windows.Thickness]::new(0,0,0,4)
    }
    $g = [System.Windows.Controls.Grid]::new()
    foreach ($w in @(24, [double]::NaN, [double]::NaN)) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        if ($w -eq 24) { $cd.Width = [System.Windows.GridLength]::new(24) }
        elseif ($g.ColumnDefinitions.Count -eq 1) { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
        else { $cd.Width = [System.Windows.GridLength]::Auto }
        $g.ColumnDefinitions.Add($cd)
    }
    $mk = [System.Windows.Controls.TextBlock]@{ Text=$colours.icon; FontSize=13; FontFamily=[System.Windows.Media.FontFamily]::new('Segoe UI Symbol'); Foreground=New-Brush $colours.ic; HorizontalAlignment='Center'; VerticalAlignment='Center' }
    $nl = [System.Windows.Controls.TextBlock]@{ Text=$Label; FontSize=13; Foreground=New-Brush $colours.name; VerticalAlignment='Center'; Margin=[System.Windows.Thickness]::new(8,0,0,0) }
    $tl = [System.Windows.Controls.TextBlock]@{ Text=$Time; FontSize=11; Foreground=New-Brush $colours.time; FontFamily=[System.Windows.Media.FontFamily]::new('Consolas'); VerticalAlignment='Center' }
    [System.Windows.Controls.Grid]::SetColumn($mk, 0)
    [System.Windows.Controls.Grid]::SetColumn($nl, 1)
    [System.Windows.Controls.Grid]::SetColumn($tl, 2)
    $g.Children.Add($mk) | Out-Null
    $g.Children.Add($nl) | Out-Null
    $g.Children.Add($tl) | Out-Null
    $border.Child = $g
    $StagesPanel.Children.Add($border) | Out-Null
}

$Script:LastQrPath = $null

function Show-MonitorError {
    param([string]$Message)
    # Write to log file
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [ERROR] $Message"
    try { Append-Log $MONITOR_LOG (($line) + "`r`n") } catch {}
    try { Append-Log $Script:_rawLog (($line) + "`r`n") } catch {}
    # Show in UI - window stays open
    try {
        $ErrorText.Text    = $Message
        $ErrorLogPath.Text = "Log: $MONITOR_LOG"
        $ErrorPanel.Visibility = 'Visible'
    } catch {}
}

function Load-QrImage ($QrPath) {
    if (-not $QrPath -or -not (Test-Path $QrPath) -or $QrPath -eq $Script:LastQrPath) { return }
    try {
        $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource   = [Uri]::new($QrPath)
        $bmp.EndInit(); $bmp.Freeze()
        $QrImage.Source    = $bmp
        $Script:LastQrPath = $QrPath
    } catch {
        $QrImage.Source = $null
        Append-Log $Script:_rawLog ("[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [WARN] QR image load failed: $($_.Exception.Message)" + "`r`n")
    }
}

# ---------------------------------------------------------------------------
# UI refresh
# ---------------------------------------------------------------------------
$Script:CompletionTime = $null

function Update-UI {
    $state = Read-JsonFile $STATE_FILE
    $ts    = Read-JsonFile $TS_JSON

    if (-not $state) {
        # State file doesn't exist yet - check if orchestrator task is running
        try {
            $task = Get-ScheduledTask -TaskName 'WinDeploy-Resume' -ErrorAction Stop
            $orchStatus = switch ($task.State) {
                'Running' { '● Orchestrator running - waiting for state.json...' }
                'Ready'   { '○ Orchestrator not yet started - waiting for trigger...' }
                default   { "Task state: $($task.State)" }
            }
        } catch { $orchStatus = 'WinDeploy-Resume task not found' }
        $FooterNote.Text = $orchStatus
        return
    }

    $started = try { [datetime]::Parse((Get-StateProp $state 'BootstrappedAt' '')).ToString('HH:mm:ss') } catch { '...' }
    $SubtitleLabel.Text = "$env:COMPUTERNAME  ·  Started $started"
    $ElapsedLabel.Text  = Format-Elapsed (Get-StateProp $state 'BootstrappedAt' '')
    $RebootLabel.Text   = (Get-StateProp $state 'RebootCount' 0).ToString()

    $done  = @(Get-StateProp $state 'CompletedStages' @()).Count
    $total = $STAGE_ORDER.Count
    $pct   = [int](($done / $total) * 100)
    $StageCountLabel.Text = "$($done + 1) / $total"
    $PctLabel.Text        = "$pct%"
    $ProgressFill.Width   = ($pct / 100) * ($Window.Width - 60)

    # Stages
    $StagesPanel.Children.Clear()
    foreach ($name in $STAGE_ORDER) {
        $st   = Get-StageStatus $state $name
        $tss  = ''
        $timestamps = Get-StateProp $state 'StageTimestamps' $null
        if ($timestamps) {
            # StageTimestamps may be a PSCustomObject (from ConvertFrom-Json) or a hashtable.
            # PSObject.Properties lookup is safe on both - avoids StrictMode "property missing" throw.
            $tsVal = $timestamps.PSObject.Properties[$name]
            if ($tsVal) {
                $tss = try { [datetime]::Parse($tsVal.Value).ToString('HH:mm:ss') } catch { '' }
            }
        }
        $timeStr = switch ($st) { 'complete' { $tss } 'running' { 'Running...' } 'failed' { 'Failed' } default { 'Waiting' } }
        Add-StageRow -Label $STAGE_LABELS[$name] -Status $st -Time $timeStr
    }

    # Tailscale QR panel
    $showTs = ((Get-StateProp $state 'CurrentStage' '') -eq 'InstallTailscale') -or ($ts -and $ts.AuthUrl -and -not $ts.Registered)
    if ($showTs -and $ts -and $ts.AuthUrl) {
        $TailscalePanel.Visibility = 'Visible'
        $TailscaleUrlText.Text     = $ts.AuthUrl
        if ($ts.QrPath) { Load-QrImage $ts.QrPath }
        if ($ts.Registered) {
            $TailscaleStatusText.Text               = "Registered as $($ts.MachineName)"
            $TailscaleStatusText.Foreground         = New-Brush '#4ADE80'
            $TailscaleStatusBorder.Background       = New-Brush '#0E1A0E'
            $TailscaleStatusBorder.BorderBrush      = New-Brush '#2D4A2D'
        } else {
            $TailscaleStatusText.Text               = 'Waiting for scan...'
            $TailscaleStatusText.Foreground         = New-Brush '#60A5FA'
            $TailscaleStatusBorder.Background       = New-Brush '#0E1520'
            $TailscaleStatusBorder.BorderBrush      = New-Brush '#1A3050'
        }
    } else {
        $TailscalePanel.Visibility = 'Collapsed'
    }

    # Log tail
    $LogPanel.Children.Clear()
    if (Test-Path $SESSION_LOG) {
        try {
            $lines = @(Get-Content $SESSION_LOG -Tail 15 -Encoding UTF8 |
                       Where-Object { $_.Trim() } | Select-Object -Last 5)
            foreach ($line in $lines) {
                $col = switch -Wildcard ($line) {
                    '*[SUCCESS]*' { '#4ADE80' } '*[ERROR]*' { '#F87171' }
                    '*[WARN]*'    { '#F59E0B' } '*[SECTION]*' { '#378ADD' } default { '#555555' }
                }
                $display = $line -replace '^\[\d{4}-\d{2}-\d{2} ','[' `
                                 -replace '\] \[(INFO|SUCCESS|SECTION)\] ','] '
                $LogPanel.Children.Add([System.Windows.Controls.TextBlock]@{
                    Text         = $display
                    FontSize     = 11
                    FontFamily   = [System.Windows.Media.FontFamily]::new('Consolas')
                    Foreground   = New-Brush $col
                    TextTrimming = 'CharacterEllipsis'
                    Margin       = [System.Windows.Thickness]::new(0,1,0,1)
                }) | Out-Null
            }
        } catch { Append-Log $Script:_rawLog ("[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [WARN] Stage row render failed: $($_.Exception.Message)" + "`r`n") }
    }

    # Completion
    if ((Get-StateProp $state 'DeployComplete' $false)) {
        $TitleLabel.Text           = 'Deployment complete'
        $StatusBadge.Text          = 'Complete'
        $StatusBadge.Foreground    = New-Brush '#4ADE80'
        $StatusBorder.Background   = New-Brush '#0E1A0E'
        $StatusBorder.BorderBrush  = New-Brush '#2D4A2D'
        $TailscalePanel.Visibility = 'Collapsed'
        if (-not $Script:CompletionTime) { $Script:CompletionTime = Get-Date }
        $remaining = $CLOSE_DELAY - [int]((Get-Date) - $Script:CompletionTime).TotalSeconds
        if ($remaining -le 0) { $Window.Close(); return }
        $CloseCountdown.Text = "Closing in $remaining s"
        $CloseBtn.Visibility = 'Visible'
    } else {
        $lbl = if ($STAGE_LABELS[(Get-StateProp $state 'CurrentStage' '')]) { $STAGE_LABELS[(Get-StateProp $state 'CurrentStage' '')] } else { '...' }
        $StatusBadge.Text         = $lbl
        $StatusBadge.Foreground   = New-Brush '#60A5FA'
        $StatusBorder.Background  = New-Brush '#0E1520'
        $StatusBorder.BorderBrush = New-Brush '#1A3050'
    }

    # --- Footer: state file age + orchestrator status ---
    $stateAge    = ''
    $orchStatus  = ''
    $lastErrLine = ''

    # How long ago was state.json last written
    try {
        $mtime    = (Get-Item $STATE_FILE -ErrorAction Stop).LastWriteTime
        $ageSecs  = [int](([datetime]::Now - $mtime).TotalSeconds)
        $stateAge = if ($ageSecs -lt 60)   { "${ageSecs}s ago" }
                    elseif ($ageSecs -lt 3600) { "$([int]($ageSecs/60))m ago" }
                    else                   { "$([int]($ageSecs/3600))h ago" }
    } catch { $stateAge = '?' }

    # Is the Resume task currently running?
    try {
        $task = Get-ScheduledTask -TaskName 'WinDeploy-Resume' -ErrorAction Stop
        $isRunning = $task.State -eq 'Running'
        $orchStatus = if ($isRunning) { '● Running' } else { '○ Waiting' }
        $RunNowBtn.IsEnabled = -not $isRunning
    } catch { $orchStatus = 'task?'; $RunNowBtn.IsEnabled = $false }

    # Last error from state
    $lastErr = Get-StateProp $state 'LastError' ''
    if ($lastErr) {
        $lastErrStage = Get-StateProp $state 'LastErrorStage' ''
        $lastErrLine  = "  ·  Last error: [$lastErrStage] $($lastErr.ToString().Split([char]10)[0])"
    }

    $FooterNote.Text = "Updated $stateAge  ·  $orchStatus  ·  $(Get-Date -Format 'HH:mm:ss')$lastErrLine"

    # Highlight footer in amber when state hasn't changed in 10+ minutes and task isn't running
    try {
        if ($ageSecs -gt 600 -and $orchStatus -ne '● Running') {
            $FooterNote.Foreground = New-Brush '#F59E0B'   # amber - stale, nothing running
        } else {
            $FooterNote.Foreground = New-Brush '#555555'
        }
    } catch {}
}

# --- Load version from manifest.json and wire up commit link ---
$Script:CommitUrl = ''
try {
    $manifestPath = Join-Path $Script:_scriptDir '..\manifest.json'
    if (-not (Test-Path $manifestPath)) {
        $manifestPath = Join-Path $DEPLOY_ROOT 'repo\manifest.json'
    }
    if (Test-Path $manifestPath) {
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $sha   = $m.commit_sha
        $repo  = $m.repository
        $genAt = try { [datetime]::Parse($m.generated_at).ToString('yyyy-MM-dd HH:mm') } catch { '' }
        if ($sha -and $sha -ne 'pending') {
            $short = $sha.Substring(0, 7)
            $Script:CommitUrl = "https://github.com/$repo/commit/$sha"
            $VersionLabel.Text = "commit $short  ·  $genAt"
        } else {
            $VersionLabel.Text = 'commit pending (manifest not signed yet)'
        }
    }
} catch {
    $VersionLabel.Text = ''
}

$VersionLabel.Add_MouseLeftButtonUp({
    if ($Script:CommitUrl) {
        try { Start-Process $Script:CommitUrl } catch {}
    }
})

$CloseBtn.Add_Click({ $Window.Close() })

$RunNowBtn.Add_Click({
    try {
        $task = Get-ScheduledTask -TaskName 'WinDeploy-Resume' -ErrorAction Stop
        if ($task.State -eq 'Running') {
            $FooterNote.Text = 'Orchestrator is already running.'
        } else {
            Start-ScheduledTask -TaskName 'WinDeploy-Resume' -ErrorAction Stop
            $FooterNote.Text = 'Orchestrator started.'
            $RunNowBtn.IsEnabled = $false
        }
    } catch {
        $FooterNote.Text = "Could not start task: $($_.Exception.Message)"
    }
})

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds($REFRESH_MS)
$timer.Add_Tick({ try { Update-UI } catch { Show-MonitorError "Refresh error: $($_.Exception.Message)" } })
$Window.Add_Loaded({
    # Clamp window into the primary screen's work area.
    # CenterScreen handles the normal case; this catches edge cases like
    # a saved position from a now-disconnected second monitor.
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $win = $Window

    # Ensure the window is not wider/taller than the work area
    if ($win.ActualWidth  -gt $workArea.Width)  { $win.Width  = $workArea.Width  - 40 }
    if ($win.ActualHeight -gt $workArea.Height) { $win.Height = $workArea.Height - 40 }

    # Clamp left/top so the window is fully visible
    if ($win.Left -lt $workArea.Left) { $win.Left = $workArea.Left + 20 }
    if ($win.Top  -lt $workArea.Top)  { $win.Top  = $workArea.Top  + 20 }
    if (($win.Left + $win.ActualWidth)  -gt $workArea.Right)  {
        $win.Left = $workArea.Right - $win.ActualWidth - 20
    }
    if (($win.Top  + $win.ActualHeight) -gt $workArea.Bottom) {
        $win.Top  = $workArea.Bottom - $win.ActualHeight - 20
    }

    try { Update-UI } catch {
        Show-MonitorError "Startup error: $($_.Exception.Message)"
    }
    $timer.Start()
})
$Window.Add_Closed({ $timer.Stop() })

# Write startup entry to monitor log before ShowDialog blocks
$null = try {
    $startLine = "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] Monitor started. PID:$PID User:$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Append-Log $MONITOR_LOG (($startLine) + "`r`n")
} catch {}

# ShowDialog blocks until window closes. Any exception here is a WPF-level
# crash (e.g. missing assembly) - log it and show a fallback MessageBox so
# the user sees the error rather than the window silently disappearing.
try {
    [void]$Window.ShowDialog()
} catch {
    $crashMsg = "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [FATAL] Monitor crashed: $($_.Exception.Message) Line:$($_.InvocationInfo.ScriptLineNumber)"
    try { Append-Log $MONITOR_LOG (($crashMsg) + "`r`n") } catch {}
    try { Append-Log $Script:_rawLog (($crashMsg) + "`r`n") } catch {}
    # Show a Windows MessageBox since the WPF window is gone
    [System.Windows.MessageBox]::Show(
        "WinDeploy Monitor crashed:`n`n$($_.Exception.Message)`n`nCheck: $MONITOR_LOG",
        'WinDeploy Monitor Error',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}
