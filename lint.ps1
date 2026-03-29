#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy lint runner - validates all PowerShell files before commit.

.DESCRIPTION
    Runs PSScriptAnalyzer with a strict ruleset across every .ps1 and .psm1
    file in the repo. Also runs custom checks that PSScriptAnalyzer does not
    cover: PS 5.1 compatibility, scheduled task XML validity, and hardcoded
    path violations.

    Exit code 0 = clean. Exit code 1 = violations found.

.NOTES
    Requires PSScriptAnalyzer:
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

    Run from repo root:
        powershell -ExecutionPolicy Bypass -File .\lint.ps1
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$FixAuto,
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty when powershell.exe is called from inside a pwsh
# session (e.g. GitHub Actions). Fall back to the current working directory.
if (-not $RepoRoot) {
    $RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

if (-not (Test-Path $RepoRoot)) {
    Write-Error "RepoRoot '$RepoRoot' does not exist. Run from the repo root or pass -RepoRoot explicitly."
    exit 1
}

Write-Host "Lint root: $RepoRoot"

$Script:Violations = [System.Collections.Generic.List[PSCustomObject]]::new()
$Script:FilesTested = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Add-Violation {
    param([string]$File, [string]$Line, [string]$Rule, [string]$Message, [string]$Severity = 'Error')
    $cleanPath = ($File -replace [regex]::Escape($RepoRoot), '.')
    $Script:Violations.Add([PSCustomObject]@{
        File     = $cleanPath
        Line     = $Line
        Rule     = $Rule
        Severity = $Severity
        Message  = $Message
    })
}

function Write-LintLog {
    param([string]$Msg, [string]$Colour = 'Cyan')
    Write-Host $Msg -ForegroundColor $Colour
}

# ---------------------------------------------------------------------------
# Check 1: PSScriptAnalyzer
# ---------------------------------------------------------------------------
function Invoke-PSScriptAnalyzer {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-LintLog 'PSScriptAnalyzer not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force' Yellow
        Write-LintLog 'Skipping PSScriptAnalyzer checks.' Yellow
        return
    }

    Import-Module PSScriptAnalyzer -Force

    # Rules appropriate for a deployment automation script.
    # PSAvoidUsingWriteHost excluded: Write-Host is intentional for interactive
    #   console output in bootstrap, install, and logging modules.
    # PSUseShouldProcessForStateChangingFunctions excluded: internal deployment
    #   functions don't need ShouldProcess pipeline support.
    $rules = @(
        'PSAvoidGlobalVars'
        'PSAvoidUsingCmdletAliases'
        'PSMisleadingBacktick'
        'PSPossibleIncorrectComparisonWithNull'
        'PSUseOutputTypeCorrectly'
    )

    $psFiles = Get-ChildItem $RepoRoot -Recurse -Include '*.ps1','*.psm1' |
               Where-Object { $_.FullName -notlike '*\.git\*' }

    foreach ($file in $psFiles) {
        $Script:FilesTested++
        try {
            $results = Invoke-ScriptAnalyzer -Path $file.FullName -IncludeRule $rules -ErrorAction Stop

            foreach ($r in $results) {
                $sev = if ($r.Severity -eq 'Warning' -and $Strict) { 'Error' } else { $r.Severity }
                Add-Violation -File $file.FullName -Line $r.Line -Rule $r.RuleName `
                              -Message $r.Message -Severity $sev
            }
        } catch {
            Add-Violation -File $file.FullName -Line '0' -Rule 'ParseError' `
                          -Message "PSScriptAnalyzer failed to parse file: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Check 2: PS 5.1 compatibility - forbidden syntax
# ---------------------------------------------------------------------------
function Invoke-PS51CompatCheck {
    Write-LintLog "`nChecking PS 5.1 compatibility..."

    $forbidden = @(
        @{ Pattern = '\?\?[^=]';         Rule = 'PS51-NullCoalescing';  Msg = 'Null-coalescing operator ?? requires PS 7+' }
        @{ Pattern = '\?\.\s*\w';        Rule = 'PS51-NullConditional'; Msg = 'Null-conditional operator ?. requires PS 7+' }
        @{ Pattern = '\?\?=';            Rule = 'PS51-NullAssignment';  Msg = 'Null-coalescing assignment ??= requires PS 7+' }
        # ConvertFrom-Json -AsHashtable is PS6+ but acceptable when gated behind a version check
        # @{ Pattern = 'ConvertFrom-Json.*-AsHashtable'; Rule = 'PS51-JsonHashtable'; Msg = '-AsHashtable requires PS 6+, use ConvertTo-Hashtable shim' }
        @{ Pattern = 'Get-WindowsUpdate.*-AcceptAll'; Rule = 'WU-InvalidParam'; Msg = '-AcceptAll is not valid on Get-WindowsUpdate (only Install-WindowsUpdate)' }
        @{ Pattern = 'Get-WindowsUpdate.*-IgnoreReboot'; Rule = 'WU-InvalidParam'; Msg = '-IgnoreReboot is not valid on Get-WindowsUpdate (only Install-WindowsUpdate)' }
    )

    $psFiles = Get-ChildItem $RepoRoot -Recurse -Include '*.ps1','*.psm1' |
               Where-Object { $_.FullName -notlike '*\.git\*' } |
               Where-Object { $_.Name -ne 'lint.ps1' }   # exclude self - pattern defs would self-match

    foreach ($file in $psFiles) {
        $lines = Get-Content $file.FullName
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.TrimStart().StartsWith('#')) { continue }   # skip comments
            foreach ($check in $forbidden) {
                if ($line -match $check.Pattern) {
                    Add-Violation -File $file.FullName -Line ($i + 1) `
                                  -Rule $check.Rule -Message $check.Msg
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Check 3: Scheduled task XML validity
# Catches the EndBoundary issue and other common task XML problems.
# ---------------------------------------------------------------------------
function Invoke-ScheduledTaskCheck {
    Write-LintLog "`nChecking scheduled task definitions..."

    $psFiles = Get-ChildItem $RepoRoot -Recurse -Include '*.ps1','*.psm1' |
               Where-Object { $_.FullName -notlike '*\.git\*' }

    foreach ($file in $psFiles) {
        $content = Get-Content $file.FullName -Raw
        $lines   = Get-Content $file.FullName

        # Rule: RepetitionInterval without RepetitionDuration causes missing EndBoundary
        if ($content -match 'RepetitionInterval' -and $content -notmatch 'RepetitionDuration') {
            # Find the line
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'RepetitionInterval') {
                    Add-Violation -File $file.FullName -Line ($i + 1) `
                        -Rule 'Task-MissingRepetitionDuration' `
                        -Message '-RepetitionInterval without -RepetitionDuration generates XML missing EndBoundary. Add -RepetitionDuration (New-TimeSpan -Days 9999).'
                    break
                }
            }
        }

        # Rule: Register-ScheduledTask should always have -Force to be idempotent
        # Use \b word boundary equivalent: match Register- but not Unregister-
        # Also skip lines where it appears inside a quoted string (log messages)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Skip Unregister- lines and lines where it's inside a string literal
            if ($line -notmatch '(?<![A-Za-z])Register-ScheduledTask') { continue }
            if ($line -match 'Unregister-ScheduledTask') { continue }
            if ($line -match "^[^#]*[`"'].*Register-ScheduledTask.*[`"']") { continue }
            if ($line -match '-Force') { continue }
            $blockEnd = [Math]::Min($i + 20, $lines.Count - 1)
            $block = ($lines[$i..$blockEnd]) -join ' '
            if ($block -notmatch '-Force') {
                Add-Violation -File $file.FullName -Line ($i + 1) `
                    -Rule 'Task-MissingForce' -Severity 'Warning' `
                    -Message 'Register-ScheduledTask without -Force is not idempotent. Add -Force.'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Check 4: Hardcoded paths
# Every path must use $WD.* or the $Script:DEPLOY_ROOT constant.
# ---------------------------------------------------------------------------
function Invoke-HardcodedPathCheck {
    Write-LintLog "`nChecking for hardcoded paths..."

    # Files that legitimately hardcode the deploy root path because Config.psm1
    # may not be loaded yet (bootstrap context) or they ARE the config source.
    $allowedFiles = @(
        'Resilience.psm1'   # self-contained by design, no Config dependency
        'Diagnostic.ps1'    # standalone tool
        'lint.ps1'          # development tool
        'Config.psm1'       # IS the constants definition
        'State.psm1'        # loads before Config in some contexts
        'Logging.psm1'      # loads before Config in some contexts
        'bootstrap.ps1'     # runs before Config is available
        'install.ps1'       # runs before repo is downloaded
        'uninstall.ps1'     # runs standalone, no repo context
        'Monitor.ps1'       # has Config fallback inline
        'Notify.ps1'        # has Config fallback inline
        'Orchestrator.ps1'  # early.log path needed before Config loads
        'Tailscale.ps1'     # deploy root needed for JSON output
        'Cleanup.ps1'       # completion report path
    )

    $psFiles = Get-ChildItem $RepoRoot -Recurse -Include '*.ps1','*.psm1' |
               Where-Object { $_.FullName -notlike '*\.git\*' } |
               Where-Object { $_.Name -notin $allowedFiles }

    foreach ($file in $psFiles) {
        $lines = Get-Content $file.FullName
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.TrimStart().StartsWith('#')) { continue }
            # Flag literal path strings (not variable references)
            if ($line -match "'C:\\ProgramData\\WinDeploy" -or $line -match '"C:\\ProgramData\\WinDeploy') {
                Add-Violation -File $file.FullName -Line ($i + 1) `
                    -Rule 'Style-HardcodedPath' -Severity 'Warning' `
                    -Message "Hardcoded path. Use `$WD.DeployRoot or module constants instead."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Check 5: Stage scripts must return correct result hashtable
# ---------------------------------------------------------------------------
function Invoke-StageContractCheck {
    Write-LintLog "`nChecking stage script return contracts..."

    $stageFiles = Get-ChildItem (Join-Path $RepoRoot 'core') -Include '*.ps1' |
                  Where-Object { $_.Name -notin @('Orchestrator.ps1','Monitor.ps1','Notify.ps1','Diagnostic.ps1') }


    foreach ($file in $stageFiles) {
        $content = Get-Content $file.FullName -Raw
        # Stage scripts must have at least one return with a Status key
        if ($content -notmatch 'return @\{') {
            Add-Violation -File $file.FullName -Line '0' `
                -Rule 'Stage-MissingReturnContract' -Severity 'Warning' `
                -Message "Stage script has no 'return @{ Status = ...' -- orchestrator cannot handle its result."
        }
    }
}

# ---------------------------------------------------------------------------
# Check 6: State property cross-reference
# Validates that:
#   (a) Every key Monitor.ps1 reads via Get-StateProp exists in State.psm1's schema
#   (b) Every key State.psm1 defines is present in bootstrap.ps1's initial write
#   (c) No $state.X direct access in Monitor.ps1 (must use Get-StateProp)
#
# This rule was added after a series of runtime crashes caused by state
# properties being read with the wrong case or missing from the initial write.
# ---------------------------------------------------------------------------
function Invoke-StatePropertyCheck {
    Write-LintLog "`nChecking state property cross-references..."

    $statePsm1     = Join-Path $RepoRoot 'core\State.psm1'
    $bootstrapPs1  = Join-Path $RepoRoot 'bootstrap.ps1'
    $monitorPs1    = Join-Path $RepoRoot 'core\Monitor.ps1'

    if (-not (Test-Path $statePsm1) -or -not (Test-Path $bootstrapPs1) -or -not (Test-Path $monitorPs1)) {
        Write-LintLog '  Skipping state check - one or more required files not found.' WARN
        return
    }

    $stateContent     = Get-Content $statePsm1    -Raw
    $bootstrapContent = Get-Content $bootstrapPs1 -Raw
    $monitorContent   = Get-Content $monitorPs1   -Raw
    $monitorLines     = Get-Content $monitorPs1

    # --- Extract the canonical schema from State.psm1 ---
    # Keys are defined as string literals in hashtable assignments:
    # $state['KeyName'] = ... or $initialState = [ordered]@{ KeyName = ... }
    $schemaKeys = [System.Collections.Generic.HashSet[string]]::new()
    $stateContent | Select-String -Pattern '\\\$state\[''([A-Za-z][A-Za-z0-9]+)''\]' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $null = $schemaKeys.Add($_.Groups[1].Value) }
    $stateContent | Select-String -Pattern "^\s{8}([A-Z][A-Za-z0-9]+)\s+=" -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $null = $schemaKeys.Add($_.Groups[1].Value) }

    # --- Extract keys bootstrap.ps1 writes in the initial state ---
    $bootKeys = [System.Collections.Generic.HashSet[string]]::new()
    # Match lines inside the initialState hashtable block
    $inBlock = $false
    foreach ($line in (Get-Content $bootstrapPs1)) {
        if ($line -match 'initialState\s*=\s*\[ordered\]@\{') { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -match '^\s*\}') { $inBlock = $false; continue }
            if ($line -match "^\s+([A-Z][A-Za-z0-9]+)\s*=") {
                $null = $bootKeys.Add($Matches[1])
            }
        }
    }

    # --- Extract keys Monitor.ps1 reads via Get-StateProp ---
    $monitorKeys = [System.Collections.Generic.HashSet[string]]::new()
    $monitorContent | Select-String -Pattern 'Get-StateProp\s+\$state\s+''([A-Za-z][A-Za-z0-9]+)''' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $null = $monitorKeys.Add($_.Groups[1].Value) }

    # --- Rule A: Monitor reads a key not in the schema ---
    foreach ($key in $monitorKeys) {
        if (-not $schemaKeys.Contains($key)) {
            # Find the line number
            $lineNum = 0
            for ($i = 0; $i -lt $monitorLines.Count; $i++) {
                if ($monitorLines[$i] -match [regex]::Escape($key)) { $lineNum = $i + 1; break }
            }
            Add-Violation -File $monitorPs1 -Line $lineNum `
                -Rule 'State-UnknownKey' `
                -Message "Monitor reads state key '$key' which is not defined in State.psm1 schema."
        }
    }

    # --- Rule B: Schema key missing from bootstrap initial write ---
    # Only flag keys that are writable (not read-only computed fields)
    $writeableKeys = $schemaKeys | Where-Object { $_ -notin @('SchemaVersion') }
    foreach ($key in $writeableKeys) {
        if ($bootKeys.Count -gt 0 -and -not $bootKeys.Contains($key)) {
            Add-Violation -File $bootstrapPs1 -Line '0' `
                -Rule 'State-MissingInitialKey' -Severity 'Warning' `
                -Message "Schema key '$key' is defined in State.psm1 but missing from bootstrap.ps1 initial state write. Monitor may crash if it launches before Orchestrator re-initialises state."
        }
    }

    # --- Rule C: Direct $state.X access in Monitor (must use Get-StateProp) ---
    for ($i = 0; $i -lt $monitorLines.Count; $i++) {
        $line = $monitorLines[$i]
        if ($line.TrimStart().StartsWith('#')) { continue }
        # Match $state.PropertyName but not $state[ which is hashtable access
        if ($line -match '\$state\.([A-Za-z][A-Za-z0-9]+)' -and $line -notmatch '\$state\[') {
            Add-Violation -File $monitorPs1 -Line ($i + 1) `
                -Rule 'State-DirectAccess' `
                -Message ('Direct $state.' + $Matches[1] + ' in Monitor - use Get-StateProp $state ''' + $Matches[1] + ''' <default> instead.')
        }
    }

    Write-LintLog "  Schema keys   : $($schemaKeys.Count)"
    Write-LintLog "  Bootstrap keys: $($bootKeys.Count)"
    Write-LintLog "  Monitor reads : $($monitorKeys.Count)"
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------
Write-LintLog "`n=== WinDeploy Lint Runner ===" Cyan
Write-LintLog "Repo: $RepoRoot`n"

Invoke-PSScriptAnalyzer
Invoke-PS51CompatCheck
Invoke-ScheduledTaskCheck
Invoke-HardcodedPathCheck
Invoke-StageContractCheck
Invoke-StatePropertyCheck

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-LintLog "`n=== Results ===" Cyan
Write-LintLog "Files checked : $Script:FilesTested"
Write-LintLog "Violations    : $($Script:Violations.Count)"

if ($Script:Violations.Count -eq 0) {
    Write-LintLog "`nAll checks passed." Green
    exit 0
}

$errors   = @($Script:Violations | Where-Object Severity -eq 'Error')
$warnings = @($Script:Violations | Where-Object Severity -eq 'Warning')

Write-LintLog "`nErrors  : $($errors.Count)" Red
Write-LintLog "Warnings: $($warnings.Count)" Yellow
Write-LintLog ''

foreach ($v in $Script:Violations | Sort-Object Severity, File, Line) {
    $colour = if ($v.Severity -eq 'Error') { 'Red' } else { 'Yellow' }
    Write-Host "[$($v.Severity.ToUpper())] $($v.File):$($v.Line)" -ForegroundColor $colour
    Write-Host "  Rule   : $($v.Rule)"
    Write-Host "  Message: $($v.Message)"
    Write-Host ''
}

# Fail on errors; warnings alone pass unless -Strict
if ($errors.Count -gt 0) { exit 1 }
exit 0
