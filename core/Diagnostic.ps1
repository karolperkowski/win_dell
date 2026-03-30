#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy diagnostic - run this manually to find out why tasks are failing.

.DESCRIPTION
    Does not modify anything. Prints a full environment report to the console
    and writes it to C:\ProgramData\WinDeploy\Logs\diagnostic.log

.NOTES
    Run as: powershell.exe -ExecutionPolicy Bypass -File .\core\Diagnostic.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DEPLOY_ROOT = 'C:\ProgramData\WinDeploy'
$LOG_DIR     = "$DEPLOY_ROOT\Logs"
$DIAG_LOG    = "$LOG_DIR\diagnostic.log"

# Ensure log dir exists before anything else
if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

$lines = [System.Collections.Generic.List[string]]::new()

function Check {
    param([string]$Label, [scriptblock]$Test)
    try {
        $result = & $Test
        $line   = "[OK]   $Label : $result"
    } catch {
        $line = "[FAIL] $Label : $($_.Exception.Message)"
    }
    $lines.Add($line)
    $colour = if ($line -match '^\[OK\]') { 'Green' } else { 'Red' }
    Write-Host $line -ForegroundColor $colour
}

Write-Host "`n=== WinDeploy Diagnostic ===" -ForegroundColor Cyan
Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

# --- Environment ---
Check 'PowerShell version'     { $PSVersionTable.PSVersion.ToString() }
Check 'Running as'             { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
Check 'OS'                     { (Get-CimInstance Win32_OperatingSystem).Caption }
Check 'Execution policy'       { Get-ExecutionPolicy }

# --- Paths ---
Check 'Deploy root exists'     { Test-Path $DEPLOY_ROOT }
Check 'Log dir exists'         { Test-Path $LOG_DIR }
Check 'State file exists'      { Test-Path "$DEPLOY_ROOT\state.json" }

$repoDir = "$DEPLOY_ROOT\repo"
Check 'Repo dir exists'        { Test-Path $repoDir }
Check 'Orchestrator exists'    { Test-Path "$repoDir\core\Orchestrator.ps1" }
Check 'Config.psm1 exists'     { Test-Path "$repoDir\core\Config.psm1" }
Check 'State.psm1 exists'      { Test-Path "$repoDir\core\State.psm1" }
Check 'Logging.psm1 exists'    { Test-Path "$repoDir\core\Logging.psm1" }
Check 'Monitor.ps1 exists'     { Test-Path "$repoDir\core\Monitor.ps1" }
Check 'Notify.ps1 exists'      { Test-Path "$repoDir\core\Notify.ps1" }
Check 'settings.json exists'   { Test-Path "$repoDir\config\settings.json" }

# --- Scheduled tasks ---
foreach ($task in @('WinDeploy-Resume','WinDeploy-Monitor','WinDeploy-Notify')) {
    Check "Task: $task" {
        $t = Get-ScheduledTask -TaskName $task -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $task -ErrorAction SilentlyContinue
        $lastResult = if ($info) { "LastResult=0x{0:X}" -f $info.LastTaskResult } else { 'no run yet' }
        "$($t.State) | $lastResult"
    }
}

# --- Module import test ---
Check 'Import Config.psm1'  {
    Import-Module "$repoDir\core\Config.psm1" -Force -DisableNameChecking -ErrorAction Stop
    $cfg = Get-WDConfig
    "OK - DeployRoot=$($cfg.DeployRoot)"
}
Check 'Import State.psm1'   {
    Import-Module "$repoDir\core\State.psm1"   -Force -DisableNameChecking -ErrorAction Stop
    'OK'
}
Check 'Import Logging.psm1' {
    Import-Module "$repoDir\core\Logging.psm1" -Force -DisableNameChecking -ErrorAction Stop
    'OK'
}

# --- State file content ---
if (Test-Path "$DEPLOY_ROOT\state.json") {
    Write-Host "`n--- state.json ---" -ForegroundColor Cyan
    Get-Content "$DEPLOY_ROOT\state.json" | Write-Host
}

# --- Last task errors from event log ---
Write-Host "`n--- Task Scheduler event log (last 10 WinDeploy entries) ---" -ForegroundColor Cyan
try {
    Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TaskScheduler/Operational'
        StartTime = (Get-Date).AddHours(-24)
    } -MaxEvents 100 -ErrorAction Stop |
    Where-Object { $_.Message -match 'WinDeploy' } |
    Select-Object -Last 10 |
    ForEach-Object { Write-Host "  $($_.TimeCreated) [$($_.Id)] $($_.Message.Split("`n")[0])" }
} catch {
    Write-Host "  Could not read event log: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- Write report to file ---
$header = @(
    "WinDeploy Diagnostic Report"
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "Machine:   $env:COMPUTERNAME"
    "User:      $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    "="*60
)
($header + $lines) | Set-Content -Path $DIAG_LOG -Encoding UTF8
Write-Host "`nReport saved to: $DIAG_LOG" -ForegroundColor Cyan
