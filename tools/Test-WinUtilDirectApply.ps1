#Requires -Version 5.1
<#
.SYNOPSIS
    Dry-run (or full real-apply) for the WinUtil direct-apply path.

.DESCRIPTION
    Loads the helper functions from core/WinTweaks.ps1, downloads the
    WinUtil bundle, and parses its embedded JSON configs.

    Default mode is dry-run: reports what each preset ID would do without
    writing anything. With -Apply, mounts user hives and applies every
    preset ID exactly as WinTweaks Pass 1 would.

.PARAMETER Apply
    Apply the preset for real. Without this, the script is read-only.

.PARAMETER Skip
    Preset IDs to skip when -Apply is set. Useful to drop slow tweaks
    (e.g. WPFTweaksDiskCleanup, WPFTweaksRestorePoint) during validation.
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$Skip = @()
)

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

if ($Apply) {
    # Real-apply needs every helper from WinTweaks.ps1
    $funcAsts = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    )
} else {
    $wantFuncs = @(
        'Get-WinUtilBundle'
        'Get-WinUtilConfigsFromBundle'
        'Get-WinUtilPresetIds'
    )
    $funcAsts = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wantFuncs -contains $node.Name },
        $true
    )
}

# Stub logging helpers so the bundle/config helpers can call them
function Write-LogInfo    { param($m) Write-Host "INFO  $m" }
function Write-LogWarning { param($m) Write-Host "WARN  $m" -ForegroundColor Yellow }
function Write-LogError   { param($m) Write-Host "ERR   $m" -ForegroundColor Red }
function Write-LogSuccess { param($m) Write-Host "OK    $m" -ForegroundColor Green }
function Write-LogSection { param($m) Write-Host "=== $m ===" -ForegroundColor Cyan }
function Set-StageExtra   { param($StageName, $Key, $Value) }   # no-op for test

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

# Hive-mount script-scope state (only used in -Apply mode)
$Script:UserHiveRoots   = @()
$Script:DefaultHiveRoot = $null
$Script:LoadedHiveKeys  = @()

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
Write-Host '=== Summary (resolution) ==='
Write-Host "  tweaks resolved : $($resolved.tweak)"
Write-Host "  features resolved: $($resolved.feature)"
Write-Host "  installs skipped : $($resolved.install)"
Write-Host "  unknown IDs      : $($resolved.unknown.Count)"
if ($resolved.unknown.Count -gt 0) {
    Write-Host "  unknown list     : $($resolved.unknown -join ', ')" -ForegroundColor Red
    exit 1
}

if (-not $Apply) { exit 0 }

Write-Host ''
Write-Host '=== Step 5: APPLY preset (real changes!) ===' -ForegroundColor Yellow

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Must run as Administrator for -Apply.' -ForegroundColor Red
    exit 2
}

Mount-AllUserHives
$totalsw  = [System.Diagnostics.Stopwatch]::StartNew()
$applied  = 0; $skipped = 0; $errors = 0; $errList = @()
try {
    foreach ($id in $presetIds) {
        if ($Skip -contains $id) {
            Write-Host "  [SKIP-CLI] $id" -ForegroundColor DarkYellow
            $skipped++
            continue
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Host "  >>> $id"
        $status = $null
        try {
            $status = Invoke-WinUtilPresetEntry -Id $id -TweaksConfig $tweaks -FeatureConfig $feature
        } catch {
            Write-Host "      THREW: $($_.Exception.Message)" -ForegroundColor Red
            $errors++; $errList += "${id}: $($_.Exception.Message)"
            continue
        } finally {
            $sw.Stop()
        }
        $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        switch ($status) {
            'applied'         { Write-Host "      OK ($elapsed s)" -ForegroundColor Green; $applied++ }
            'skipped-install' { Write-Host "      skipped-install ($elapsed s)" -ForegroundColor DarkYellow; $skipped++ }
            'unknown'         { Write-Host "      UNKNOWN" -ForegroundColor Red; $errors++ }
            default           { Write-Host "      status=$status" }
        }
    }
} finally {
    Dismount-AllUserHives
    $totalsw.Stop()
}

Write-Host ''
Write-Host '=== Apply summary ==='
Write-Host ("  total elapsed : {0:N1} min" -f $totalsw.Elapsed.TotalMinutes)
Write-Host "  applied       : $applied"
Write-Host "  skipped       : $skipped"
Write-Host "  errors        : $errors"
if ($errList.Count -gt 0) {
    Write-Host '  error list    :' -ForegroundColor Red
    $errList | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}
if ($errors -gt 0) { exit 1 } else { exit 0 }
