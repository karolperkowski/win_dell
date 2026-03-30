#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy reinstall — clean uninstall + fresh install in one step.
.DESCRIPTION
    Removes all WinDeploy components, then performs a fresh install.
    Fully unattended — no prompts, no confirmation dialogs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$REPO_RAW = 'https://raw.githubusercontent.com/karolperkowski/win_dell/main'

# Auto-elevate if not admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Host '[Reinstall] Not running as Administrator. Re-launching elevated...' -ForegroundColor Yellow
    $scriptContent = (Invoke-WebRequest -Uri "$REPO_RAW/reinstall.ps1" -UseBasicParsing).Content
    $tempScript = Join-Path $env:TEMP 'windeploy_reinstall.ps1'
    [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::UTF8)
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$tempScript`""
    Write-Host '[Reinstall] Elevated process launched.' -ForegroundColor Green
    exit 0
}

Write-Host '=== WinDeploy Reinstall ===' -ForegroundColor Cyan
Write-Host ''

# Step 1: Uninstall
Write-Host '[Step 1/2] Running uninstall...' -ForegroundColor Yellow
try {
    $uninstallContent = (Invoke-WebRequest -Uri "$REPO_RAW/uninstall.ps1" -UseBasicParsing).Content
    $uninstallScript = Join-Path $env:TEMP 'windeploy_uninstall.ps1'
    [System.IO.File]::WriteAllText($uninstallScript, $uninstallContent, [System.Text.Encoding]::UTF8)
    & powershell.exe -ExecutionPolicy Bypass -File $uninstallScript -Silent
    Write-Host '[Step 1/2] Uninstall complete.' -ForegroundColor Green
} catch {
    Write-Host "[Step 1/2] Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Continuing with install anyway...' -ForegroundColor Yellow
}

Write-Host ''

# Step 2: Install
Write-Host '[Step 2/2] Running fresh install...' -ForegroundColor Yellow
try {
    $installContent = (Invoke-WebRequest -Uri "$REPO_RAW/install.ps1" -UseBasicParsing).Content
    $installScript = Join-Path $env:TEMP 'windeploy_install.ps1'
    [System.IO.File]::WriteAllText($installScript, $installContent, [System.Text.Encoding]::UTF8)
    & powershell.exe -ExecutionPolicy Bypass -File $installScript
    Write-Host '[Step 2/2] Install complete.' -ForegroundColor Green
} catch {
    Write-Host "[Step 2/2] Install failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== Reinstall finished ===' -ForegroundColor Cyan
