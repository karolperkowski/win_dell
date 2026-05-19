#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Power Settings

.DESCRIPTION
    Activates the Ultimate Performance power plan (or falls back to High
    Performance if duplication is blocked on Home SKUs), then disables every
    automatic display-off / sleep / hibernate behaviour and pins lid-close,
    sleep-button, and power-button actions to "Do nothing" -- on BOTH AC
    (plugged-in) and DC (battery). Works on Windows 10 and 11. Uses
    powercfg.exe exclusively for portability.

    Settings consumed from $Config['Stages']['PowerSettings']:
        PowerPlan                  : 'Ultimate' | 'High' (default 'Ultimate')
        DisableButtons             : bool (default $true)
        DisableSleepAndScreenOff   : bool (default $true)
        DisableHibernateFile       : bool (default $true)

    Per the orchestrator return contract (see CLAUDE.md), this stage returns
    exactly one hashtable: @{ Status; Message }.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'PowerSettings',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference   = 'None'

$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
# State.psm1 is best-effort -- a fresh ad-hoc run outside the orchestrator
# may not have a state file. Set-StageExtra calls are wrapped in try/catch.
try {
    Import-Module (Join-Path $coreDir 'State.psm1') -DisableNameChecking -Force
} catch {
    # Logger not initialised yet; defer the warning until after Initialize-Logger.
    $Script:StateModuleLoadError = $_.Exception.Message
}

Initialize-Logger -Stage $StageName

if ($Script:StateModuleLoadError) {
    Write-LogWarning "State.psm1 unavailable: $($Script:StateModuleLoadError) -- StageExtras writes will be skipped."
}

# ---------------------------------------------------------------------------
# Stable Windows GUIDs (Win10 + Win11)
# ---------------------------------------------------------------------------
$SUB_SLEEP        = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # Sleep
$SUB_DISPLAY      = '7516b95f-f776-4464-8c53-06167f40cc99'   # Display
$SUB_BUTTONS      = '4f971e89-eebd-4455-a8de-9e59040e7347'   # Power buttons and lid

$SETTING_STANDBY  = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'   # Sleep after
$SETTING_DISPLAY  = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'   # Display off after
$SETTING_HIBER    = '9d7815a6-7ee4-497e-8888-515a05f02364'   # Hibernate after

$SETTING_LID      = '5ca83367-6e45-459f-a27b-476b1d01c936'   # Lid close action
$SETTING_SLEEPBTN = '96996bc0-ad50-47ec-923b-6f41874dd9eb'   # Sleep button action
$SETTING_PWRBTN   = '7648efa3-dd9c-4e3e-b566-50f929386280'   # Power button action

# Standard plan GUIDs (always present, no duplication required for these two)
$PLAN_HIGH_PERF   = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'   # High Performance
$PLAN_ULTIMATE    = 'e9a42b02-d5df-448d-aa00-03f14749eb61'   # Ultimate Performance template

$NEVER     = 0   # Sleep/Display/Hibernate "after" value: 0 minutes = Never
$DO_NOTHING = 0  # Lid/Sleep/Power button action: 0 = Do nothing

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-Powercfg {
    <#
    Runs powercfg.exe with the supplied arguments. Captures stdout+stderr into
    a local array so nothing leaks into the stage's return pipeline (CLAUDE.md
    "single biggest footgun" rule). Returns @{ ExitCode; Output }.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    $captured = @(& powercfg.exe @Arguments 2>&1)
    $exit = $LASTEXITCODE
    return @{ ExitCode = $exit; Output = $captured }
}

function Set-StageExtraSafe {
    param([string]$Key, $Value)
    try {
        if (Get-Command Set-StageExtra -ErrorAction SilentlyContinue) {
            Set-StageExtra -StageName $StageName -Key $Key -Value $Value
        }
    } catch {
        Write-LogWarning "  Could not write StageExtras[$Key]: $($_.Exception.Message)"
    }
}

function Get-ActivePowerSchemeGuid {
    $r = Invoke-Powercfg -Arguments @('/getactivescheme')
    $joined = ($r.Output -join "`n")
    if ($joined -match 'GUID:\s+([0-9a-f-]{36})') {
        return $Matches[1]
    }
    throw "Could not parse active power scheme GUID from: $joined"
}

function Set-PowerValue {
    <#
    Applies the same value to both AC and DC for a single setting.
    The setting GUID is identical for AC and DC; only the verb differs.
    #>
    param(
        [string]$SchemeGuid,
        [string]$SubGroupGuid,
        [string]$SettingGuid,
        [int]$Value,
        [string]$Description
    )
    Write-LogInfo "  $Description (AC+DC) => $Value"
    $rAc = Invoke-Powercfg -Arguments @('/setacvalueindex', $SchemeGuid, $SubGroupGuid, $SettingGuid, "$Value")
    $rDc = Invoke-Powercfg -Arguments @('/setdcvalueindex', $SchemeGuid, $SubGroupGuid, $SettingGuid, "$Value")
    if ($rAc.ExitCode -ne 0) {
        Write-LogWarning "    powercfg /setacvalueindex exit $($rAc.ExitCode) for $Description"
    }
    if ($rDc.ExitCode -ne 0) {
        Write-LogWarning "    powercfg /setdcvalueindex exit $($rDc.ExitCode) for $Description"
    }
}

function Activate-BestPerformancePlan {
    <#
    Tries to duplicate the Ultimate Performance template and activate the
    duplicate. On failure (Home SKUs commonly block this with 0x8007007A or
    a "scheme not found" error), falls back to the always-present High
    Performance plan.

    Returns @{ Guid; Label } describing the plan that ended up active.
    #>
    param([string]$Requested = 'Ultimate')

    if ($Requested -eq 'High') {
        Write-LogInfo 'PowerPlan=High requested -- activating High Performance directly.'
        $rAct = Invoke-Powercfg -Arguments @('/setactive', $PLAN_HIGH_PERF)
        if ($rAct.ExitCode -ne 0) {
            Write-LogWarning "powercfg /setactive High Performance exit $($rAct.ExitCode): $($rAct.Output -join '; ')"
        }
        return @{ Guid = $PLAN_HIGH_PERF; Label = 'High Performance' }
    }

    Write-LogInfo 'Attempting to duplicate the Ultimate Performance plan...'
    $r = Invoke-Powercfg -Arguments @('-duplicatescheme', $PLAN_ULTIMATE)
    $joined = ($r.Output -join "`n")
    Write-LogInfo "  powercfg -duplicatescheme exit $($r.ExitCode)"

    if ($r.ExitCode -eq 0 -and $joined -match 'GUID:\s+([0-9a-f-]{36})') {
        $newGuid = $Matches[1]
        Write-LogSuccess "  Duplicated Ultimate Performance as $newGuid"
        $rAct = Invoke-Powercfg -Arguments @('/setactive', $newGuid)
        if ($rAct.ExitCode -ne 0) {
            Write-LogWarning "  /setactive on new Ultimate GUID exit $($rAct.ExitCode) -- falling back to High Performance."
            Invoke-Powercfg -Arguments @('/setactive', $PLAN_HIGH_PERF) | Out-Null
            return @{ Guid = $PLAN_HIGH_PERF; Label = 'High Performance (fallback after activate failure)' }
        }
        return @{ Guid = $newGuid; Label = 'Ultimate Performance' }
    }

    # Ultimate template not present (Home SKU) or duplication blocked.
    Write-LogWarning "  Ultimate Performance not available (output: $joined). Falling back to High Performance."
    $rAct = Invoke-Powercfg -Arguments @('/setactive', $PLAN_HIGH_PERF)
    if ($rAct.ExitCode -ne 0) {
        Write-LogWarning "  /setactive High Performance exit $($rAct.ExitCode)."
    }
    return @{ Guid = $PLAN_HIGH_PERF; Label = 'High Performance' }
}

function Verify-PowerSettings {
    param([string]$SchemeGuid)

    Write-LogInfo 'Verifying power settings (AC + DC)...'
    $subgroups = @($SUB_SLEEP, $SUB_DISPLAY, $SUB_BUTTONS)
    $combined  = ''
    foreach ($sub in $subgroups) {
        $r = Invoke-Powercfg -Arguments @('/query', $SchemeGuid, $sub)
        $combined += "`n" + ($r.Output -join "`n")
    }

    $nonZero = 0
    foreach ($verb in @('AC','DC')) {
        $rx = [regex]::Matches($combined, "Current $verb Power Setting Index:\s+0x([0-9a-fA-F]+)")
        foreach ($m in $rx) {
            $val = [Convert]::ToInt32($m.Groups[1].Value, 16)
            if ($val -ne 0) {
                $nonZero++
                Write-LogWarning "  Non-zero $verb value detected: $val"
            }
        }
    }
    if ($nonZero -eq 0) {
        Write-LogSuccess '  All measured AC + DC indices are 0 (Never / Do nothing).'
    } else {
        Write-LogWarning "  $nonZero setting(s) are not zero -- see warnings above."
    }
    return $nonZero
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-LogInfo "Stage '$StageName' starting."

    # Resolve stage config (the orchestrator passes the entire settings.json
    # hashtable; per-stage settings live under .Stages.<StageName>).
    $stageCfg = @{}
    if ($Config -and $Config['Stages'] -and $Config['Stages'][$StageName]) {
        $stageCfg = $Config['Stages'][$StageName]
    }

    $requestedPlan = 'Ultimate'
    if ($stageCfg['PowerPlan']) { $requestedPlan = [string]$stageCfg['PowerPlan'] }

    $disableButtons = $true
    if ($stageCfg.ContainsKey('DisableButtons')) {
        $disableButtons = [bool]$stageCfg['DisableButtons']
    }

    $disableSleep = $true
    if ($stageCfg.ContainsKey('DisableSleepAndScreenOff')) {
        $disableSleep = [bool]$stageCfg['DisableSleepAndScreenOff']
    }

    $disableHiberFile = $true
    if ($stageCfg.ContainsKey('DisableHibernateFile')) {
        $disableHiberFile = [bool]$stageCfg['DisableHibernateFile']
    }

    # --- Plan selection -----------------------------------------------------
    $plan = Activate-BestPerformancePlan -Requested $requestedPlan
    Write-LogSuccess "Active plan: $($plan.Label) -- $($plan.Guid)"
    Set-StageExtraSafe -Key 'SchemeGuid'  -Value $plan.Guid
    Set-StageExtraSafe -Key 'SchemeLabel' -Value $plan.Label

    # Pick up the actually-active scheme (may differ if /setactive failed).
    $activeGuid = Get-ActivePowerSchemeGuid
    Write-LogInfo "Active power scheme GUID (confirmed): $activeGuid"

    # --- Sleep / display / hibernate (AC + DC) -----------------------------
    if ($disableSleep) {
        Write-LogInfo 'Disabling display-off / sleep / hibernate on AC and DC...'
        Set-PowerValue -SchemeGuid $activeGuid -SubGroupGuid $SUB_DISPLAY `
                       -SettingGuid $SETTING_DISPLAY -Value $NEVER `
                       -Description 'Turn off display after'
        Set-PowerValue -SchemeGuid $activeGuid -SubGroupGuid $SUB_SLEEP `
                       -SettingGuid $SETTING_STANDBY -Value $NEVER `
                       -Description 'Sleep after'
        Set-PowerValue -SchemeGuid $activeGuid -SubGroupGuid $SUB_SLEEP `
                       -SettingGuid $SETTING_HIBER -Value $NEVER `
                       -Description 'Hibernate after'
    } else {
        Write-LogInfo 'DisableSleepAndScreenOff=false -- leaving sleep/display/hibernate values untouched.'
    }

    # --- Buttons (AC + DC) -------------------------------------------------
    if ($disableButtons) {
        Write-LogInfo 'Setting lid / sleep button / power button to "Do nothing" on AC and DC...'
        Set-PowerValue -SchemeGuid $activeGuid -SubGroupGuid $SUB_BUTTONS `
                       -SettingGuid $SETTING_LID -Value $DO_NOTHING `
                       -Description 'Lid close action'
        Set-PowerValue -SchemeGuid $activeGuid -SubGroupGuid $SUB_BUTTONS `
                       -SettingGuid $SETTING_SLEEPBTN -Value $DO_NOTHING `
                       -Description 'Sleep button action'
        Set-PowerValue -SchemeGuid $activeGuid -SubGroupGuid $SUB_BUTTONS `
                       -SettingGuid $SETTING_PWRBTN -Value $DO_NOTHING `
                       -Description 'Power button action'
    } else {
        Write-LogInfo 'DisableButtons=false -- leaving lid / sleep / power button actions untouched.'
    }

    # --- Commit the scheme so values become effective immediately ---------
    Invoke-Powercfg -Arguments @('/setactive', $activeGuid) | Out-Null
    Write-LogSuccess 'Power scheme committed.'

    # --- Hibernate file (reclaims disk space) -----------------------------
    if ($disableHiberFile) {
        Write-LogInfo 'Disabling hibernation file (hiberfil.sys)...'
        Invoke-Powercfg -Arguments @('/hibernate', 'off') | Out-Null
    } else {
        Write-LogInfo 'DisableHibernateFile=false -- leaving hiberfil.sys in place.'
    }

    # --- Verify ------------------------------------------------------------
    $nonZero = Verify-PowerSettings -SchemeGuid $activeGuid
    Set-StageExtraSafe -Key 'VerifiedNonZeroCount' -Value $nonZero

    Write-LogSuccess "Power settings stage complete. Plan: $($plan.Label)."
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = "Power settings configured (plan: $($plan.Label))." }

} catch {
    Write-LogError "Power settings stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
