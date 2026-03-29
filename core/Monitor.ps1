#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Monitor - Live deployment progress window.

.DESCRIPTION
    Launched at logon by the WinDeploy-Monitor scheduled task.
    Polls state.json every 3 seconds. Shows stage status, metrics, live log tail.
    When InstallTailscale is the current stage, displays the QR code and auth URL
    so the machine can be registered without a keyboard.
    Auto-closes 30 seconds after DeployComplete = true.
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
function Write-Early {
    param([string]$Msg)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Msg"
    Write-Host $line
    try {
        $dir = Split-Path $Script:_rawLog
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        Add-Content -Path $Script:_rawLog -Value $line -Encoding UTF8
    } catch {}
}
Write-Early "=== $(Split-Path -Leaf $MyInvocation.MyCommand.Path) started (PID $PID) ==="
Write-Early "PSScriptRoot : $PSScriptRoot"
Write-Early "Running as   : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Early "ExecutionPolicy: $(Get-ExecutionPolicy)"


# Load shared constants - provides $WD.DeployRoot, $WD.StageOrder, etc.
$Script:_cfgPath = Join-Path $PSScriptRoot 'Config.psm1'
if (Test-Path $Script:_cfgPath) {
    Import-Module $Script:_cfgPath -DisableNameChecking -Force
}

$DEPLOY_ROOT  = if ($WD) { $WD.DeployRoot    } else { 'C:\ProgramData\WinDeploy' }
$STATE_FILE   = if ($WD) { $WD.StateFile     } else { "$DEPLOY_ROOT\state.json" }
$SESSION_LOG  = "$DEPLOY_ROOT\Logs\session.log"
$TS_JSON      = if ($WD) { $WD.TailscaleJson } else { "$DEPLOY_ROOT\tailscale.json" }
$STAGE_ORDER  = if ($WD) { @($WD.StageOrder) } else { @('WindowsUpdate','PowerSettings','Debloat','WinTweaks','InstallDellSupportAssist','InstallDellPowerManager','InstallTailscale','Cleanup') }
$STAGE_LABELS = if ($WD) { $WD.StageLabels   } else { @{} }
$REFRESH_MS   = 3000
$CLOSE_DELAY  = 30

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Keep display and system awake while the monitor is open.
# ES_CONTINUOUS(0x80000000) | ES_DISPLAY_REQUIRED(0x00000002) | ES_SYSTEM_REQUIRED(0x00000001)
# Windows automatically reverts when this process exits — no cleanup needed.
try {
    Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' `
             -Name 'SleepGuard' -Namespace 'WinDeploy' -ErrorAction Stop
    [WinDeploy.SleepGuard]::SetThreadExecutionState(0x80000003) | Out-Null
} catch { <# non-fatal #> }

# ---------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WinDeploy Monitor" Width="640" Height="760"
    ResizeMode="CanMinimize" WindowStartupLocation="Manual"
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
      </Grid.RowDefinitions>

      <!-- Header -->
      <Grid Grid.Row="0" Margin="0,0,0,16">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock x:Name="TitleLabel" Text="Deployment in progress" FontSize="17" FontWeight="Medium" Foreground="#E0E0E0"/>
          <TextBlock x:Name="SubtitleLabel" Text="Initialising..." FontSize="12" Foreground="#555555" Margin="0,3,0,0"/>
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
            <TextBlock Text="ELAPSED" FontSize="10" Foreground="#555555" CharacterSpacing="80"/>
            <TextBlock x:Name="ElapsedLabel" Text="00:00:00" FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0" FontFamily="Consolas"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="1" Background="#1A1A1A" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="3,0,3,0">
          <StackPanel>
            <TextBlock Text="REBOOTS" FontSize="10" Foreground="#555555" CharacterSpacing="80"/>
            <TextBlock x:Name="RebootLabel" Text="0" FontSize="20" Foreground="#E0E0E0" Margin="0,4,0,0" FontFamily="Consolas"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" Background="#1A1A1A" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="6,0,0,0">
          <StackPanel>
            <TextBlock Text="STAGE" FontSize="10" Foreground="#555555" CharacterSpacing="80"/>
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
      <TextBlock Grid.Row="3" Text="STAGES" FontSize="10" Foreground="#444444" CharacterSpacing="80" Margin="0,0,0,8"/>

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
            <TextBlock Text="TAILSCALE REGISTRATION" FontSize="10" Foreground="#2A4870" CharacterSpacing="80" Margin="0,0,0,8"/>
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
      <TextBlock Grid.Row="6" Text="RECENT ACTIVITY" FontSize="10" Foreground="#444444" CharacterSpacing="80" Margin="0,0,0,8"/>
      <Border Grid.Row="7" Background="#0A0A0A" BorderBrush="#1E1E1E" BorderThickness="1" CornerRadius="5" Padding="12,10" Height="100">
        <StackPanel x:Name="LogPanel"/>
      </Border>

      <!-- Footer -->
      <Grid Grid.Row="8" Margin="0,12,0,0">
        <TextBlock x:Name="FooterNote" Text="" FontSize="10" Foreground="#333333" VerticalAlignment="Center"/>
        <TextBlock x:Name="CloseCountdown" Text="" FontSize="10" Foreground="#555555" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>

    </Grid>
  </ScrollViewer>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($XAML)
$Window = [Windows.Markup.XamlReader]::Load($reader)

$TitleLabel           = $Window.FindName('TitleLabel')
$SubtitleLabel        = $Window.FindName('SubtitleLabel')
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

function Format-Elapsed ($Iso) {
    try { $s = (Get-Date) - [datetime]::Parse($Iso); return '{0:D2}:{1:D2}:{2:D2}' -f [int]$s.TotalHours, $s.Minutes, $s.Seconds }
    catch { return '--:--:--' }
}

function Get-StageStatus ($State, $Name) {
    if (-not $State) { return 'waiting' }
    if (@($State.CompletedStages) -contains $Name) { return 'complete' }
    if (@($State.FailedStages)    -contains $Name) { return 'failed' }
    if ($State.CurrentStage -eq $Name -and -not $State.DeployComplete) { return 'running' }
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
    } catch { $QrImage.Source = $null }
}

# ---------------------------------------------------------------------------
# UI refresh
# ---------------------------------------------------------------------------
$Script:CompletionTime = $null

function Update-UI {
    $state = Read-JsonFile $STATE_FILE
    $ts    = Read-JsonFile $TS_JSON

    if ($state) {
        $started = try { [datetime]::Parse($state.bootstrappedAt).ToString('HH:mm:ss') } catch { '...' }
        $SubtitleLabel.Text = "$env:COMPUTERNAME  ·  Started $started"
        $ElapsedLabel.Text  = Format-Elapsed $state.bootstrappedAt
        $RebootLabel.Text   = if ($state.rebootCount) { [string]$state.rebootCount } else { '0' }
    } else {
        $FooterNote.Text = "Watching $STATE_FILE ..."; return
    }

    $done  = @($state.CompletedStages).Count
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
        if ($state.stageTimestamps -and $state.stageTimestamps.$name) {
            $tss = try { [datetime]::Parse($state.stageTimestamps.$name).ToString('HH:mm:ss') } catch { '' }
        }
        $timeStr = switch ($st) { 'complete' { $tss } 'running' { 'Running...' } 'failed' { 'Failed' } default { 'Waiting' } }
        Add-StageRow -Label $STAGE_LABELS[$name] -Status $st -Time $timeStr
    }

    # Tailscale QR panel
    $showTs = ($state.CurrentStage -eq 'InstallTailscale') -or ($ts -and $ts.AuthUrl -and -not $ts.Registered)
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
        } catch {}
    }

    # Completion
    if ($state.deployComplete) {
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
    } else {
        $lbl = if ($STAGE_LABELS[$state.currentStage]) { $STAGE_LABELS[$state.currentStage] } else { '...' }
        $StatusBadge.Text         = $lbl
        $StatusBadge.Foreground   = New-Brush '#60A5FA'
        $StatusBorder.Background  = New-Brush '#0E1520'
        $StatusBorder.BorderBrush = New-Brush '#1A3050'
    }

    $FooterNote.Text = "Refresh: $(Get-Date -Format 'HH:mm:ss')  ·  $DEPLOY_ROOT\Logs"
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds($REFRESH_MS)
$timer.Add_Tick({ try { Update-UI } catch { $FooterNote.Text = "Error: $($_.Exception.Message)" } })
$Window.Add_Loaded({ try { Update-UI } catch {}; $timer.Start() })
$Window.Add_Closed({ $timer.Stop() })
[void]$Window.ShowDialog()
