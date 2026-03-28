#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Monitor - Live deployment progress window.

.DESCRIPTION
    Launched at logon by the WinDeploy-Monitor scheduled task.
    Reads C:\ProgramData\WinDeploy\state.json every 3 seconds and renders
    a WPF window showing stage status, elapsed time, reboot count, and the
    last lines of session.log.

    Auto-closes 30 seconds after DeployComplete = true.
    Must run in the interactive user session (not SYSTEM) so the window is visible.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$DEPLOY_ROOT = 'C:\ProgramData\WinDeploy'
$STATE_FILE  = Join-Path $DEPLOY_ROOT 'state.json'
$SESSION_LOG = Join-Path $DEPLOY_ROOT 'Logs\session.log'
$REFRESH_MS  = 3000
$CLOSE_DELAY = 30    # seconds to wait after completion before auto-closing

$STAGE_ORDER = @(
    'WindowsUpdate'
    'PowerSettings'
    'Debloat'
    'InstallDellSupportAssist'
    'InstallDellPowerManager'
    'Cleanup'
)

$STAGE_LABELS = @{
    WindowsUpdate            = 'Windows Update'
    PowerSettings            = 'Power Settings'
    Debloat                  = 'Debloat'
    InstallDellSupportAssist = 'Dell SupportAssist'
    InstallDellPowerManager  = 'Dell Power Manager'
    Cleanup                  = 'Cleanup'
}

# ---------------------------------------------------------------------------
# WPF assemblies
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # for Screen.PrimaryScreen

# ---------------------------------------------------------------------------
# XAML layout
# ---------------------------------------------------------------------------
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WinDeploy Monitor"
    Width="620" Height="580"
    ResizeMode="CanMinimize"
    WindowStartupLocation="Manual"
    Background="#0F0F0F"
    Foreground="#E0E0E0"
    FontFamily="Consolas"
    FontSize="13">

  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E0E0E0"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
  </Window.Resources>

  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- Header -->
      <RowDefinition Height="Auto"/>   <!-- Metrics bar -->
      <RowDefinition Height="Auto"/>   <!-- Progress bar -->
      <RowDefinition Height="Auto"/>   <!-- Stages label -->
      <RowDefinition Height="*"/>      <!-- Stages list -->
      <RowDefinition Height="Auto"/>   <!-- Log label -->
      <RowDefinition Height="100"/>    <!-- Log box -->
      <RowDefinition Height="Auto"/>   <!-- Footer -->
    </Grid.RowDefinitions>

    <!-- ── Header ── -->
    <Grid Grid.Row="0" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0">
        <TextBlock x:Name="TitleLabel" Text="Deployment in progress"
                   FontSize="17" FontWeight="Medium" Foreground="#E0E0E0"/>
        <TextBlock x:Name="SubtitleLabel" Text="Loading..."
                   FontSize="12" Foreground="#555555" Margin="0,3,0,0"/>
      </StackPanel>

      <Border Grid.Column="1" Background="#0E1A0E" BorderBrush="#2D4A2D"
              BorderThickness="1" CornerRadius="4" Padding="10,5" VerticalAlignment="Center">
        <TextBlock x:Name="StatusBadge" Text="Starting..." FontSize="12"
                   Foreground="#4ADE80" FontFamily="Segoe UI"/>
      </Border>
    </Grid>

    <!-- ── Metrics bar ── -->
    <Grid Grid.Row="1" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#1A1A1A" BorderBrush="#2A2A2A"
              BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="0,0,6,0">
        <StackPanel>
          <TextBlock Text="ELAPSED" FontSize="10" Foreground="#555555"
                     FontFamily="Segoe UI" CharacterSpacing="80"/>
          <TextBlock x:Name="ElapsedLabel" Text="00:00:00"
                     FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0"
                     FontFamily="Consolas"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="1" Background="#1A1A1A" BorderBrush="#2A2A2A"
              BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="3,0,3,0">
        <StackPanel>
          <TextBlock Text="REBOOTS" FontSize="10" Foreground="#555555"
                     FontFamily="Segoe UI" CharacterSpacing="80"/>
          <TextBlock x:Name="RebootLabel" Text="0"
                     FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0"
                     FontFamily="Consolas"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="2" Background="#1A1A1A" BorderBrush="#2A2A2A"
              BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="6,0,0,0">
        <StackPanel>
          <TextBlock Text="STAGE" FontSize="10" Foreground="#555555"
                     FontFamily="Segoe UI" CharacterSpacing="80"/>
          <TextBlock x:Name="StageCountLabel" Text="- / -"
                     FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0"
                     FontFamily="Consolas"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ── Progress bar ── -->
    <Grid Grid.Row="2" Margin="0,0,0,18">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid Grid.Row="0" Margin="0,0,0,6">
        <TextBlock Text="Overall progress" FontSize="11" Foreground="#555555" FontFamily="Segoe UI"/>
        <TextBlock x:Name="PctLabel" Text="0%" FontSize="11" Foreground="#378ADD"
                   FontFamily="Segoe UI" HorizontalAlignment="Right"/>
      </Grid>
      <Border Grid.Row="1" Background="#1E1E1E" CornerRadius="2" Height="5">
        <Border x:Name="ProgressFill" Background="#378ADD" CornerRadius="2"
                HorizontalAlignment="Left" Width="0"/>
      </Border>
    </Grid>

    <!-- ── Stages ── -->
    <TextBlock Grid.Row="3" Text="STAGES" FontSize="10" Foreground="#444444"
               FontFamily="Segoe UI" CharacterSpacing="80" Margin="0,0,0,8"/>

    <ItemsControl Grid.Row="4" x:Name="StagesList" Margin="0,0,0,12">
      <ItemsControl.ItemTemplate>
        <DataTemplate>
          <Border x:Name="StageBorder" Margin="0,0,0,4" CornerRadius="5"
                  Padding="12,9" BorderThickness="1">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="StageIcon" Text="○"
                         FontSize="13" VerticalAlignment="Center"
                         HorizontalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="StageNameText"
                         Margin="8,0,0,0" VerticalAlignment="Center"
                         FontFamily="Segoe UI" FontSize="13"/>
              <TextBlock Grid.Column="2" x:Name="StageTimeText"
                         FontFamily="Consolas" FontSize="11"
                         VerticalAlignment="Center"/>
            </Grid>
          </Border>
        </DataTemplate>
      </ItemsControl.ItemTemplate>
    </ItemsControl>

    <!-- ── Log ── -->
    <TextBlock Grid.Row="5" Text="RECENT ACTIVITY" FontSize="10" Foreground="#444444"
               FontFamily="Segoe UI" CharacterSpacing="80" Margin="0,0,0,8"/>

    <Border Grid.Row="6" Background="#0A0A0A" BorderBrush="#1E1E1E"
            BorderThickness="1" CornerRadius="5" Padding="12,10">
      <ItemsControl x:Name="LogList">
        <ItemsControl.ItemTemplate>
          <DataTemplate>
            <TextBlock x:Name="LogLineText" FontFamily="Consolas" FontSize="11"
                       TextTrimming="CharacterEllipsis" Margin="0,1"/>
          </DataTemplate>
        </ItemsControl.ItemTemplate>
      </ItemsControl>
    </Border>

    <!-- ── Footer ── -->
    <Grid Grid.Row="7" Margin="0,12,0,0">
      <TextBlock x:Name="FooterNote" Text="Refreshing..."
                 FontSize="10" Foreground="#333333" FontFamily="Segoe UI"
                 VerticalAlignment="Center"/>
      <TextBlock x:Name="CloseCountdown" Text=""
                 FontSize="10" Foreground="#555555" FontFamily="Segoe UI"
                 HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </Grid>

  </Grid>
</Window>
'@

# ---------------------------------------------------------------------------
# Build the window
# ---------------------------------------------------------------------------
$reader = [System.Xml.XmlNodeReader]::new($XAML)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Grab named elements
$TitleLabel     = $Window.FindName('TitleLabel')
$SubtitleLabel  = $Window.FindName('SubtitleLabel')
$StatusBadge    = $Window.FindName('StatusBadge')
$ElapsedLabel   = $Window.FindName('ElapsedLabel')
$RebootLabel    = $Window.FindName('RebootLabel')
$StageCountLabel= $Window.FindName('StageCountLabel')
$PctLabel       = $Window.FindName('PctLabel')
$ProgressFill   = $Window.FindName('ProgressFill')
$StagesList     = $Window.FindName('StagesList')
$LogList        = $Window.FindName('LogList')
$FooterNote     = $Window.FindName('FooterNote')
$CloseCountdown = $Window.FindName('CloseCountdown')

# Position: bottom-right corner of primary screen with 20px margin
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$Window.Left = $screen.Right  - $Window.Width  - 20
$Window.Top  = $screen.Bottom - $Window.Height - 20

# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------

function Read-State {
    if (-not (Test-Path $STATE_FILE)) { return $null }
    try {
        $raw = Get-Content $STATE_FILE -Raw -Encoding UTF8 -ErrorAction Stop
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Get-LastLogLines {
    param([int]$Count = 5)
    if (-not (Test-Path $SESSION_LOG)) { return @() }
    try {
        $lines = Get-Content $SESSION_LOG -Tail ($Count * 3) -Encoding UTF8 -ErrorAction Stop
        # Return last $Count non-empty lines
        return @($lines | Where-Object { $_.Trim() -ne '' } | Select-Object -Last $Count)
    } catch { return @() }
}

function Format-Elapsed {
    param([string]$StartIso)
    try {
        $start = [datetime]::Parse($StartIso)
        $span  = (Get-Date) - $start
        return '{0:D2}:{1:D2}:{2:D2}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds
    } catch { return '--:--:--' }
}

function Get-StageStatus {
    param($State, [string]$StageName)
    if (-not $State) { return 'waiting' }
    $completed = @($State.CompletedStages)
    $failed    = @($State.FailedStages)
    if ($completed -contains $StageName) { return 'complete' }
    if ($failed    -contains $StageName) { return 'failed'   }
    if ($State.CurrentStage -eq $StageName -and -not $State.DeployComplete) { return 'running' }
    return 'waiting'
}

# ---------------------------------------------------------------------------
# UI update - runs on the Dispatcher thread
# ---------------------------------------------------------------------------

$Script:CompletionTime   = $null
$Script:CountdownSeconds = $CLOSE_DELAY

function Update-UI {
    $state = Read-State

    # ── Header ──
    if ($state) {
        $machine = $env:COMPUTERNAME
        $started = try { [datetime]::Parse($state.bootstrappedAt).ToString('HH:mm:ss') } catch { '...' }
        $SubtitleLabel.Text = "$machine  ·  Started $started"
    }

    if (-not $state) {
        $StatusBadge.Text       = 'Waiting for deploy...'
        $StatusBadge.Foreground = '#555555'
        $FooterNote.Text        = "Watching $STATE_FILE"
        return
    }

    # ── Metrics ──
    $ElapsedLabel.Text  = Format-Elapsed $state.bootstrappedAt
    $RebootLabel.Text   = [string]($state.rebootCount ?? 0)

    # ── Stages ──
    $completed = @($state.CompletedStages).Count
    $total     = $STAGE_ORDER.Count
    $pct       = [int](($completed / $total) * 100)

    $StageCountLabel.Text       = "$($completed + 1) / $total"
    $PctLabel.Text              = "$pct%"
    $ProgressFill.Width         = ($pct / 100) * 550   # approximate track width

    # Build stage row objects
    $stageItems = foreach ($name in $STAGE_ORDER) {
        $status = Get-StageStatus -State $state -StageName $name
        $ts     = if ($state.stageTimestamps -and $state.stageTimestamps.$name) {
            try { [datetime]::Parse($state.stageTimestamps.$name).ToString('HH:mm:ss') } catch { '' }
        } else { '' }

        [PSCustomObject]@{
            Name    = $STAGE_LABELS[$name]
            Status  = $status
            Time    = switch ($status) {
                'complete' { $ts }
                'running'  { 'Running...' }
                'failed'   { 'Failed' }
                default    { 'Waiting' }
            }
        }
    }
    $StagesList.ItemsSource = $stageItems

    # Colour each row after binding (ItemsControl generates containers after ItemsSource is set)
    $StagesList.UpdateLayout()
    for ($i = 0; $i -lt $STAGE_ORDER.Count; $i++) {
        $container = $StagesList.ItemContainerGenerator.ContainerFromIndex($i)
        if (-not $container) { continue }

        $border   = $container.ContentTemplate.FindName('StageBorder',   $container) 2>$null
        $icon     = $container.ContentTemplate.FindName('StageIcon',     $container) 2>$null
        $nameText = $container.ContentTemplate.FindName('StageNameText', $container) 2>$null
        $timeText = $container.ContentTemplate.FindName('StageTimeText', $container) 2>$null

        if (-not $border) { continue }

        switch ($stageItems[$i].Status) {
            'complete' {
                $border.Background   = '#0E1A0E'
                $border.BorderBrush  = '#1D3A1D'
                $icon.Text           = [char]0x2713
                $icon.Foreground     = '#4ADE80'
                $nameText.Foreground = '#CCCCCC'
                $timeText.Foreground = '#4ADE80'
            }
            'running' {
                $border.Background   = '#0E1520'
                $border.BorderBrush  = '#1A3050'
                $icon.Text           = [char]0x25B6
                $icon.Foreground     = '#60A5FA'
                $nameText.Foreground = '#E0E0E0'
                $timeText.Foreground = '#60A5FA'
            }
            'failed' {
                $border.Background   = '#1F0E0E'
                $border.BorderBrush  = '#3D1A1A'
                $icon.Text           = [char]0x2717
                $icon.Foreground     = '#F87171'
                $nameText.Foreground = '#F87171'
                $timeText.Foreground = '#F87171'
            }
            default {
                $border.Background   = '#131313'
                $border.BorderBrush  = '#1E1E1E'
                $icon.Text           = [char]0x2013
                $icon.Foreground     = '#444444'
                $nameText.Foreground = '#444444'
                $timeText.Foreground = '#444444'
            }
        }
    }

    # ── Log tail ──
    $logLines = Get-LastLogLines -Count 5
    $logItems = foreach ($line in $logLines) {
        # Strip the timestamp prefix we added in logging module: [yyyy-MM-dd HH:mm:ss] [LEVEL] ...
        $display = $line -replace '^\[\d{4}-\d{2}-\d{2} ', '[' `
                         -replace '\] \[INFO\] ',    '] ' `
                         -replace '\] \[SUCCESS\] ', '] ' `
                         -replace '\] \[WARN\] ',    '] [WARN] ' `
                         -replace '\] \[ERROR\] ',   '] [ERR]  ' `
                         -replace '\] \[SECTION\] ', '] '
        [PSCustomObject]@{ Line = $display; Raw = $line }
    }
    $LogList.ItemsSource = $logItems

    # Colour log lines after binding
    $LogList.UpdateLayout()
    for ($i = 0; $i -lt @($logItems).Count; $i++) {
        $container = $LogList.ItemContainerGenerator.ContainerFromIndex($i)
        if (-not $container) { continue }
        $textBlock = $container.ContentTemplate.FindName('LogLineText', $container) 2>$null
        if (-not $textBlock) { continue }

        $raw = $logItems[$i].Raw
        $textBlock.Text = $logItems[$i].Line
        $textBlock.Foreground = switch -Wildcard ($raw) {
            '*[SUCCESS]*' { '#4ADE80' }
            '*[ERROR]*'   { '#F87171' }
            '*[WARN]*'    { '#F59E0B' }
            '*[SECTION]*' { '#378ADD' }
            default       { '#555555' }
        }
    }

    # ── Status badge and completion ──
    if ($state.deployComplete) {
        $TitleLabel.Text        = 'Deployment complete'
        $StatusBadge.Text       = 'Complete'
        $StatusBadge.Foreground = '#4ADE80'
        $StageCountLabel.Text   = "$total / $total"
        $PctLabel.Text          = '100%'
        $ProgressFill.Width     = 550

        if (-not $Script:CompletionTime) {
            $Script:CompletionTime = Get-Date
        }

        $remaining = $CLOSE_DELAY - [int]((Get-Date) - $Script:CompletionTime).TotalSeconds
        if ($remaining -le 0) {
            $Window.Close()
        } else {
            $CloseCountdown.Text = "Window closes in $remaining seconds"
        }
    } else {
        $currentStageName = $STAGE_LABELS[$state.currentStage] ?? $state.currentStage
        $StatusBadge.Text       = $currentStageName
        $StatusBadge.Foreground = '#60A5FA'
    }

    $FooterNote.Text = "Last refresh: $(Get-Date -Format 'HH:mm:ss')  ·  $DEPLOY_ROOT\Logs"
}

# ---------------------------------------------------------------------------
# DispatcherTimer - ticks on the UI thread so we can touch controls directly
# ---------------------------------------------------------------------------
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds($REFRESH_MS)
$timer.Add_Tick({
    try { Update-UI } catch {
        $FooterNote.Text = "Refresh error: $($_.Exception.Message)"
    }
})

# First paint immediately on load
$Window.Add_Loaded({
    try { Update-UI } catch {}
    $timer.Start()
})

$Window.Add_Closed({ $timer.Stop() })

# ---------------------------------------------------------------------------
# Show the window - blocks until closed
# ---------------------------------------------------------------------------
[void]$Window.ShowDialog()
