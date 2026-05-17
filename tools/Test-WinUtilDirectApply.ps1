#Requires -Version 5.1
<#
.SYNOPSIS
    Dry-run for the WinUtil direct-apply path in core/WinTweaks.ps1.

.DESCRIPTION
    Loads the helper functions from core/WinTweaks.ps1, downloads the
    WinUtil bundle, parses its embedded JSON configs, and reports what
    each preset ID would do -- without actually writing to the registry,
    changing services, or running InvokeScript blocks.

    Run this before merging changes to the WinUtil direct-apply logic to
    confirm preset IDs still resolve and the bundle's JSON shape hasn't
    drifted.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$wtPath   = Join-Path $repoRoot 'core\WinTweaks.ps1'

if (-not (Test-Path $wtPath)) {
    throw "WinTweaks.ps1 not found at $wtPath"
}

# Extract just the function definitions from WinTweaks.ps1 via AST so we
# can call them without running the stage's Main body.
$tokens = $null; $errors = $null
$ast    = [System.Management.Automation.Language.Parser]::ParseFile($wtPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "Parse errors in WinTweaks.ps1: $($errors -join '; ')" }

$wantFuncs = @(
    'Get-WinUtilBundle'
    'Get-WinUtilConfigsFromBundle'
    'Get-WinUtilPresetIds'
)
$funcAsts = $ast.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wantFuncs -contains $node.Name },
    $true
)

# Stub logging helpers so the bundle/config helpers can call them
function Write-LogInfo    { param($m) Write-Host "INFO  $m" }
function Write-LogWarning { param($m) Write-Host "WARN  $m" -ForegroundColor Yellow }
function Write-LogError   { param($m) Write-Host "ERR   $m" -ForegroundColor Red }
function Write-LogSuccess { param($m) Write-Host "OK    $m" -ForegroundColor Green }

# Source the extracted helpers into the current scope
foreach ($f in $funcAsts) {
    $sb = [scriptblock]::Create($f.Extent.Text)
    . $sb
}

# WinUtil bundle URL list lives at script scope in WinTweaks.ps1; set it here.
$Script:WinUtilBundleUrls = @(
    'https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1'
    'https://christitus.com/win'
)

Write-Host ''
Write-Host '=== Step 1: download bundle ==='
$bundleSrc = Get-WinUtilBundle

Write-Host ''
Write-Host '=== Step 2: parse embedded JSON configs ==='
$configs = Get-WinUtilConfigsFromBundle -BundleSrc $bundleSrc

Write-Host ''
Write-Host '=== Step 3: load preset ==='
$presetPath = Join-Path $repoRoot 'config\winutil-preset.json'
$presetIds  = @(Get-WinUtilPresetIds -Path $presetPath)
Write-Host "Preset: $($presetIds.Count) IDs"
foreach ($id in $presetIds) { Write-Host "  - $id" }

Write-Host ''
Write-Host '=== Step 4: resolve each preset ID against the bundle ==='
$tweaks  = $configs['tweaks']
$feature = $configs['feature']

$tweakNames   = @($tweaks.PSObject.Properties.Name)
$featureNames = @($feature.PSObject.Properties.Name)

$resolved = @{ tweak = 0; feature = 0; install = 0; unknown = @() }

foreach ($id in $presetIds) {
    if ($id -like 'WPFInstall*') {
        Write-Host "  [skip-install] $id"
        $resolved.install++
        continue
    }
    $entry  = $null
    $bucket = $null
    if ($tweakNames -contains $id) { $entry = $tweaks.$id; $bucket = 'tweak' }
    elseif ($featureNames -contains $id) { $entry = $feature.$id; $bucket = 'feature' }
    if (-not $entry) {
        Write-Host "  [UNKNOWN]  $id" -ForegroundColor Red
        $resolved.unknown += $id
        continue
    }
    $resolved[$bucket]++

    $propNames = @($entry.PSObject.Properties.Name)
    $regCount  = if ($propNames -contains 'registry' -and $entry.registry)         { @($entry.registry).Count }     else { 0 }
    $svcCount  = if ($propNames -contains 'service' -and $entry.service)           { @($entry.service).Count }      else { 0 }
    $featCount = if ($propNames -contains 'feature' -and $entry.feature)           { @($entry.feature).Count }      else { 0 }
    $scriptCt  = if ($propNames -contains 'InvokeScript' -and $entry.InvokeScript) { @($entry.InvokeScript).Count } else { 0 }

    Write-Host ("  [{0,-7}] {1,-40} reg={2} svc={3} feat={4} script={5}" -f $bucket, $id, $regCount, $svcCount, $featCount, $scriptCt)

    if ($regCount -gt 0) {
        foreach ($r in @($entry.registry)) {
            $rType = if ($r.PSObject.Properties.Name -contains 'Type') { $r.Type } else { 'DWord' }
            Write-Host ("       reg: {0}\{1} = {2} ({3})" -f $r.Path, $r.Name, $r.Value, $rType)
        }
    }
    if ($svcCount -gt 0) {
        foreach ($s in @($entry.service)) {
            Write-Host ("       svc: {0} -> {1}" -f $s.Name, $s.StartupType)
        }
    }
    if ($featCount -gt 0) {
        foreach ($f in @($entry.feature)) {
            Write-Host ("       feat: $f")
        }
    }
    if ($scriptCt -gt 0) {
        foreach ($scr in @($entry.InvokeScript)) {
            $preview = ($scr -replace '\s+', ' ').Trim()
            if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 117) + '...' }
            Write-Host "       script: $preview"
        }
    }
}

Write-Host ''
Write-Host '=== Summary ==='
Write-Host "  tweaks resolved : $($resolved.tweak)"
Write-Host "  features resolved: $($resolved.feature)"
Write-Host "  installs skipped : $($resolved.install)"
Write-Host "  unknown IDs      : $($resolved.unknown.Count)"
if ($resolved.unknown.Count -gt 0) {
    Write-Host "  unknown list     : $($resolved.unknown -join ', ')" -ForegroundColor Red
    exit 1
}
exit 0
