#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-commit hook logic -- regenerates INDEX.md and stages it if changed.
#>
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Continue'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$indexScript = Join-Path (Join-Path $RepoRoot 'tools') 'Update-Index.ps1'
if (-not (Test-Path $indexScript)) {
    Write-Host 'pre-commit: tools/Update-Index.ps1 not found, skipping index update.'
    exit 0
}

try {
    # Self-referential drift: INDEX.md's own entry records its own line count
    # and byte size, but writing INDEX.md changes both. The fixed point
    # converges in 1-2 iterations - re-run until git diff is empty (or 5
    # iterations max, defensive). Without this CI's "INDEX.md is up to date"
    # check fails on every push because pre-commit stages an INDEX whose
    # self-entry is one revision stale.
    Push-Location $RepoRoot
    try {
        for ($i = 0; $i -lt 5; $i++) {
            & $indexScript -RepoRoot $RepoRoot
            $diff = & git diff --name-only -- INDEX.md 2>$null
            if (-not $diff) { break }
            & git add INDEX.md 2>$null
        }
        Write-Host "pre-commit: INDEX.md regenerated ($($i+1) iteration(s)) and staged."
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "pre-commit: INDEX.md update failed: $_"
    # Don't block the commit over index generation
}

exit 0
