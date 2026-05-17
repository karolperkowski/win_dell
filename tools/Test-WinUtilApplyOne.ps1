#Requires -Version 5.1
<#
.SYNOPSIS
    Real-apply smoke test for the WinUtil direct-apply path.

.DESCRIPTION
    Loads helpers from core/WinTweaks.ps1, downloads the bundle, then
    actually applies ONE preset ID (default WPFToggleDetailedBSoD, which
    writes two HKLM\SYSTEM\...\CrashControl DWords) and reads the
    registry back to verify the write landed. Reverts at the end.

    Used to confirm the apply logic works on real hardware without
    triggering long-running tweaks (cleanmgr, restore point, etc.).

.PARAMETER TweakId
    Preset ID to apply. Must exist in the bundle.
#>

[CmdletBinding()]
param(
    [string]$TweakId = 'WPFToggleDetailedBSoD'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator (test writes HKLM).'
}

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$wtPath   = Join-Path $repoRoot 'core\WinTweaks.ps1'

# Stub the WinDeploy logging + state helpers
function Write-LogInfo    { param($m) Write-Host "INFO  $m" }
function Write-LogWarning { param($m) Write-Host "WARN  $m" -ForegroundColor Yellow }
function Write-LogError   { param($m) Write-Host "ERR   $m" -ForegroundColor Red }
function Write-LogSuccess { param($m) Write-Host "OK    $m" -ForegroundColor Green }
function Write-LogSection { param($m) Write-Host "=== $m ===" -ForegroundColor Cyan }
function Set-StageExtra   { param($StageName, $Key, $Value) }   # no-op for test

# Extract every function definition from WinTweaks.ps1 and source it.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($wtPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "Parse errors: $($errors -join '; ')" }
$funcAsts = $ast.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
)
foreach ($f in $funcAsts) {
    $sb = [scriptblock]::Create($f.Extent.Text)
    . $sb
}

# Script-scope state used by Mount-AllUserHives / Get-AllUserRoots
$Script:UserHiveRoots   = @()
$Script:DefaultHiveRoot = $null
$Script:LoadedHiveKeys  = @()
$Script:WinUtilBundleUrls = @(
    'https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1'
    'https://christitus.com/win'
)

Write-LogSection 'Mount user hives'
Mount-AllUserHives

try {
    Write-LogSection 'Download bundle'
    $bundleSrc = Get-WinUtilBundle

    Write-LogSection 'Parse configs'
    $configs = Get-WinUtilConfigsFromBundle -BundleSrc $bundleSrc

    Write-LogSection "Snapshot before applying $TweakId"
    $tweaks = $configs['tweaks']; $feature = $configs['feature']
    if (-not (($tweaks.PSObject.Properties.Name -contains $TweakId) -or ($feature.PSObject.Properties.Name -contains $TweakId))) {
        throw "Test tweak '$TweakId' not in bundle."
    }
    $entry = if ($tweaks.PSObject.Properties.Name -contains $TweakId) { $tweaks.$TweakId } else { $feature.$TweakId }

    $before = @{}
    if ($entry.PSObject.Properties.Name -contains 'registry' -and $entry.registry) {
        foreach ($r in @($entry.registry)) {
            $key = "$($r.Path)\$($r.Name)"
            try {
                $v = Get-ItemPropertyValue -Path $r.Path -Name $r.Name -ErrorAction Stop
                $before[$key] = $v
                Write-LogInfo "  before: $key = $v"
            } catch {
                $before[$key] = '<missing>'
                Write-LogInfo "  before: $key = <missing>"
            }
        }
    }

    Write-LogSection "Apply $TweakId"
    $status = Invoke-WinUtilPresetEntry -Id $TweakId -TweaksConfig $tweaks -FeatureConfig $feature
    Write-LogInfo "Status: $status"
    if ($status -ne 'applied') { throw "Expected 'applied', got '$status'" }

    Write-LogSection "Verify"
    $allMatched = $true
    if ($entry.PSObject.Properties.Name -contains 'registry' -and $entry.registry) {
        foreach ($r in @($entry.registry)) {
            $key = "$($r.Path)\$($r.Name)"
            $expect = $r.Value
            try { $expect = [int64]$expect } catch {}
            $actual = $null
            try { $actual = Get-ItemPropertyValue -Path $r.Path -Name $r.Name -ErrorAction Stop } catch {}
            if ($actual -eq $expect) {
                Write-LogSuccess "  match: $key = $actual"
            } else {
                Write-LogError   "  MISMATCH: $key  expected=$expect  actual=$actual"
                $allMatched = $false
            }
        }
    }

    Write-LogSection 'Revert'
    foreach ($k in $before.Keys) {
        # split into path/name
        $name = Split-Path -Leaf $k
        $path = Split-Path -Parent $k
        if ($before[$k] -eq '<missing>') {
            try { Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop; Write-LogInfo "  removed $k" } catch { Write-LogWarning "  revert remove failed for $k : $($_.Exception.Message)" }
        } else {
            try { Set-ItemProperty -Path $path -Name $name -Value $before[$k] -ErrorAction Stop; Write-LogInfo "  restored $k = $($before[$k])" } catch { Write-LogWarning "  revert set failed for $k : $($_.Exception.Message)" }
        }
    }

    if ($allMatched) {
        Write-LogSuccess "TEST PASS"
        exit 0
    } else {
        Write-LogError "TEST FAIL"
        exit 1
    }
} finally {
    Write-LogSection 'Unmount user hives'
    Dismount-AllUserHives
}
