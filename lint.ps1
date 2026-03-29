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
        @{ Pattern = 'ConvertFrom-Json.*-AsHashtable'; Rule = 'PS51-JsonHashtable'; Msg = '-AsHashtable requires PS 6+, use ConvertTo-Hashtable shim' }
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
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'Register-ScheduledTask' -and $lines[$i] -notmatch '-Force') {
                # Check surrounding lines too (multi-line call)
                $block = ($lines[$i..([Math]::Min($i+15, $lines.Count-1))]) -join ' '
                if ($block -notmatch '-Force') {
                    Add-Violation -File $file.FullName -Line ($i + 1) `
                        -Rule 'Task-MissingForce' -Severity 'Warning' `
                        -Message 'Register-ScheduledTask without -Force is not idempotent. Add -Force.'
                }
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

    $allowedFiles = @('Resilience.psm1', 'Diagnostic.ps1', 'lint.ps1')   # these are allowed to hardcode

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
# Run all checks
# ---------------------------------------------------------------------------
Write-LintLog "`n=== WinDeploy Lint Runner ===" Cyan
Write-LintLog "Repo: $RepoRoot`n"

Invoke-PSScriptAnalyzer
Invoke-PS51CompatCheck
Invoke-ScheduledTaskCheck
Invoke-HardcodedPathCheck
Invoke-StageContractCheck

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
