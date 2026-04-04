#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-commit hook logic -- regenerates INDEX.md and stages it if changed.
#>
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$indexScript = Join-Path (Join-Path $RepoRoot 'tools') 'Update-Index.ps1'
if (-not (Test-Path $indexScript)) {
    Write-Host 'pre-commit: tools/Update-Index.ps1 not found, skipping index update.'
    exit 0
}

try {
    & $indexScript -RepoRoot $RepoRoot

    # Check if INDEX.md changed
    Push-Location $RepoRoot
    $diff = & git diff --name-only -- INDEX.md 2>$null
    if ($diff) {
        # Suppress stderr (CRLF warnings) so PS 5.1 $ErrorActionPreference=Stop
        # does not treat git's informational warnings as terminating errors.
        & git add INDEX.md 2>&1 | Out-Null
        Write-Host 'pre-commit: INDEX.md updated and staged.'
    }
    Pop-Location
} catch {
    Write-Host "pre-commit: INDEX.md update failed: $_"
    # Don't block the commit over index generation
}

exit 0
