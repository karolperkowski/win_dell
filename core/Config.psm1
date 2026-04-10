#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy shared constants.

.DESCRIPTION
    Single source of truth for every path, name, and pipeline definition
    used across the framework. Import this module before any other WinDeploy
    module. All values are read-only after export.

    Import pattern (from any core script):
        Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -DisableNameChecking -Force
        $WD = Get-WDConfig
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$Script:DEPLOY_ROOT = 'C:\ProgramData\WinDeploy'
$Script:REPO_DIR    = Join-Path $Script:DEPLOY_ROOT 'repo'
$Script:LOG_DIR     = Join-Path $Script:DEPLOY_ROOT 'Logs'
$Script:STATE_FILE  = Join-Path $Script:DEPLOY_ROOT 'state.json'
$Script:TS_JSON     = Join-Path $Script:DEPLOY_ROOT 'tailscale.json'
$Script:TS_QR_PNG   = Join-Path $Script:DEPLOY_ROOT 'tailscale_qr.png'

# ---------------------------------------------------------------------------
# Scheduled task names
# ---------------------------------------------------------------------------
$Script:TASK_RESUME   = 'WinDeploy-Resume'
$Script:TASK_MONITOR  = 'WinDeploy-Monitor'
$Script:TASK_NOTIFY   = 'WinDeploy-Notify'
$Script:TASK_SAFETY   = 'WinDeploy-AutoLogonSafety'
$Script:TASK_WATCHDOG = 'WinDeploy-Watchdog'

# ---------------------------------------------------------------------------
# Pipeline: canonical stage order and display labels
# ---------------------------------------------------------------------------
$Script:STAGE_ORDER = @(
    'PowerSettings'
    'Debloat'
    'WinTweaks'
    'InstallDellSupportAssist'
    'InstallDellPowerManager'
    'InstallRustDesk'
    'InstallTailscale'
    'RemoteAccess'
    'WindowsUpdate'
    'Cleanup'
)

$Script:STAGE_LABELS = [ordered]@{
    PowerSettings            = 'Power Settings'
    Debloat                  = 'Debloat'
    WinTweaks                = 'Windows Tweaks'
    InstallDellSupportAssist = 'Dell SupportAssist'
    InstallDellPowerManager  = 'Dell Power Manager'
    InstallRustDesk          = 'RustDesk'
    InstallTailscale         = 'Tailscale'
    RemoteAccess             = 'Remote Access'
    WindowsUpdate            = 'Windows Update'
    Cleanup                  = 'Cleanup'
}

# Stages that are permitted to return 'RebootRequired' to the orchestrator
$Script:REBOOT_ALLOWED_STAGES = @('WindowsUpdate', 'InstallTailscale', 'Cleanup')

# ---------------------------------------------------------------------------
# Config object — built once at module load time, returned by Get-WDConfig.
# Using a function export instead of Export-ModuleMember -Variable because
# PS 5.1 + StrictMode does not reliably resolve module-exported variables
# across child process boundaries. Functions always work.
# ---------------------------------------------------------------------------
$Script:_config = [PSCustomObject]@{
    DeployRoot          = $Script:DEPLOY_ROOT
    RepoDir             = $Script:REPO_DIR
    LogDir              = $Script:LOG_DIR
    StateFile           = $Script:STATE_FILE
    TailscaleJson       = $Script:TS_JSON
    TailscaleQrPng      = $Script:TS_QR_PNG
    TaskResume          = $Script:TASK_RESUME
    TaskMonitor         = $Script:TASK_MONITOR
    TaskNotify          = $Script:TASK_NOTIFY
    TaskSafety          = $Script:TASK_SAFETY
    TaskWatchdog        = $Script:TASK_WATCHDOG
    StageOrder          = $Script:STAGE_ORDER
    StageLabels         = $Script:STAGE_LABELS
    RebootAllowedStages = $Script:REBOOT_ALLOWED_STAGES
}

function Get-WDConfig {
    <#
    .SYNOPSIS Returns the WinDeploy config object. Always callable after Import-Module.
    #>
    return $Script:_config
}

Export-ModuleMember -Function 'Get-WDConfig'
