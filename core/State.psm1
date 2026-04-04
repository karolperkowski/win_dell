#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy State Management Module

.DESCRIPTION
    All deployment state is stored in a single JSON file at
    C:\ProgramData\WinDeploy\state.json.

    Design principles:
      - Every write is atomic: write to .tmp then rename, so a mid-write
        crash cannot corrupt the state file.
      - Every public function is idempotent: calling it twice is safe.
      - Stage names are the single source of truth; they match the keys in
        settings.json and the filenames in /core.

.EXPORTED FUNCTIONS
    Initialize-DeployState
    Get-DeployState
    Save-DeployState
    Set-StageComplete
    Test-StageComplete
    Set-CurrentStage
    Get-CurrentStage
    Set-DeployComplete
    Test-DeployComplete
    Write-StateError
    Get-StageStatus          (returns a formatted summary table)
    Reset-DeployState        (destructive - for testing only)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared constants - provides Get-WDConfig for StageOrder, StateFile, etc.
$Script:_configPath = Join-Path $PSScriptRoot 'Config.psm1'
$Script:_wd = $null
if (Test-Path $Script:_configPath) {
    Import-Module $Script:_configPath -DisableNameChecking -Force
    if (Get-Command Get-WDConfig -ErrorAction SilentlyContinue) {
        $Script:_wd = Get-WDConfig
    }
}

# ---------------------------------------------------------------------------
# Module-scoped constants
# ---------------------------------------------------------------------------
$Script:STATE_FILE   = if ($Script:_wd) { $Script:_wd.StateFile } else { 'C:\ProgramData\WinDeploy\state.json' }
$Script:SCHEMA_VER   = 1
$Script:LOCK_TIMEOUT = 10

# Canonical pipeline order - sourced from Config.psm1, fallback inline
$Script:STAGE_ORDER  = if ($Script:_wd) { [System.Collections.Generic.List[string]]$Script:_wd.StageOrder } else {
    [System.Collections.Generic.List[string]]@(
        'PowerSettings','Debloat','WinTweaks',
        'InstallDellSupportAssist','InstallDellPowerManager',
        'InstallTailscale','WindowsUpdate','Cleanup'
    )
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------
function Invoke-WithFileLock {
    <#
    Acquires an exclusive file lock, runs the scriptblock, then releases.
    Uses a separate .lock sentinel file rather than locking the JSON itself
    so readers are never blocked by a reader.
    #>
    param([scriptblock]$ScriptBlock)

    $lockFile = "$($Script:STATE_FILE).lock"
    $waited   = 0
    $interval = 250   # ms

    while (Test-Path $lockFile) {
        Start-Sleep -Milliseconds $interval
        $waited += $interval / 1000
        if ($waited -ge $Script:LOCK_TIMEOUT) {
            # Stale lock detected - remove, pause, then verify it doesn't reappear
            Write-Warning "[State] Stale lock file detected after ${waited}s - removing."
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            if (Test-Path $lockFile) {
                # Another writer re-created the lock - wait one more cycle
                Write-Warning '[State] Lock reappeared after stale removal - another writer is active. Retrying.'
                $waited = 0
                continue
            }
            break
        }
    }

    try {
        New-Item -Path $lockFile -ItemType File -Force | Out-Null
        & $ScriptBlock
    } finally {
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    }
}

function Read-StateFile {
    <# Returns a hashtable, or $null if the file does not exist. #>
    if (-not (Test-Path $Script:STATE_FILE)) { return $null }

    $raw = Get-Content -Path $Script:STATE_FILE -Raw -Encoding UTF8
    # -AsHashtable requires PS 6+; use the ConvertTo-Hashtable shim on PS 5.1
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    $obj = $raw | ConvertFrom-Json
    return ConvertTo-Hashtable -InputObject $obj
}

function ConvertTo-Hashtable {
    <# Recursively converts PSCustomObject to ordered hashtable (PS 5.1 shim) #>
    param([Parameter(ValueFromPipeline)][object]$InputObject)
    process {
        if ($InputObject -is [System.Collections.IEnumerable] -and
            $InputObject -isnot [string]) {
            return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $ht = [ordered]@{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                $ht[$prop.Name] = ConvertTo-Hashtable $prop.Value
            }
            return $ht
        }
        return $InputObject
    }
}

function Write-StateFile {
    <#
    Atomic write: serialise to a temp file then rename over the real file.
    On NTFS, a rename within the same volume is atomic at the filesystem level.
    #>
    param([hashtable]$State)

    $tmp = "$($Script:STATE_FILE).tmp"
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Script:STATE_FILE -Force
}

function Assert-StateExists {
    if (-not (Test-Path $Script:STATE_FILE)) {
        throw "State file not found at '$($Script:STATE_FILE)'. " +
              "Run bootstrap.ps1 first, or call Initialize-DeployState."
    }
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Initialize-DeployState {
    <#
    .SYNOPSIS
        Creates the initial state file. Safe to call multiple times - will not
        overwrite an existing state file unless -Force is specified.

    .PARAMETER RepoRoot
        Path to the local copy of the deployment repo.

    .PARAMETER ConfigFile
        Full path to settings.json.

    .PARAMETER Force
        Overwrite an existing state file. Use only during testing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfigFile,
        [switch]$Force
    )

    if ((Test-Path $Script:STATE_FILE) -and -not $Force) {
        Write-Verbose "[State] State file already exists. Skipping initialisation."
        return
    }

    $state = [ordered]@{
        SchemaVersion          = $Script:SCHEMA_VER
        BootstrappedAt         = (Get-Date -Format 'o')
        LastUpdatedAt          = (Get-Date -Format 'o')
        RepoRoot               = $RepoRoot
        ConfigFile             = $ConfigFile
        CurrentStage           = $Script:STAGE_ORDER[0]
        CompletedStages        = @()
        FailedStages           = @()
        StageTimestamps        = [ordered]@{}    # stage -> ISO8601 completion time
        LastError              = $null
        LastErrorStage         = $null
        LastErrorTimestamp     = $null
        RebootCount            = 0
        DeployComplete         = $false
        DeployCompletedAt      = $null
    }

    $stateDir = Split-Path $Script:STATE_FILE -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    Invoke-WithFileLock { Write-StateFile -State $state }
    Write-Verbose "[State] State file initialised at '$($Script:STATE_FILE)'."
}

function Get-DeployState {
    <#
    .SYNOPSIS
        Returns the full deployment state as a hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    Assert-StateExists
    return Read-StateFile
}

function Save-DeployState {
    <#
    .SYNOPSIS
        Saves a modified state hashtable back to disk (atomic write).
        Use this after modifying the object returned by Get-DeployState.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $State['LastUpdatedAt'] = (Get-Date -Format 'o')
    Invoke-WithFileLock { Write-StateFile -State $State }
}

function Set-StageComplete {
    <#
    .SYNOPSIS
        Marks a named stage as successfully completed and advances the
        CurrentStage pointer to the next stage in the pipeline.

    .PARAMETER StageName
        Must be one of the values in $Script:STAGE_ORDER.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StageName)

    Assert-StateExists
    Invoke-WithFileLock {
        $state = Read-StateFile

        # Idempotency: already marked complete
        if ($state['CompletedStages'] -contains $StageName) {
            Write-Verbose "[State] Stage '$StageName' is already marked complete."
            return
        }

        # Record completion
        $state['CompletedStages'] = @($state['CompletedStages']) + $StageName
        $state['StageTimestamps'][$StageName] = (Get-Date -Format 'o')

        # Remove from failed list if it was previously recorded as failed
        if ($state['FailedStages'] -contains $StageName) {
            $state['FailedStages'] = @($state['FailedStages'] | Where-Object { $_ -ne $StageName })
        }

        # Advance current stage pointer
        $idx = $Script:STAGE_ORDER.IndexOf($StageName)
        if ($idx -ge 0 -and $idx -lt (@($Script:STAGE_ORDER).Count - 1)) {
            $state['CurrentStage'] = $Script:STAGE_ORDER[$idx + 1]
        }

        $state['LastUpdatedAt'] = (Get-Date -Format 'o')
        Write-StateFile -State $state
    }
    Write-Verbose "[State] Stage '$StageName' marked complete."
}

function Test-StageComplete {
    <#
    .SYNOPSIS
        Returns $true if the named stage has been successfully completed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$StageName)

    Assert-StateExists
    $state = Read-StateFile
    return ($state['CompletedStages'] -contains $StageName)
}

function Set-CurrentStage {
    <#
    .SYNOPSIS
        Manually overrides the CurrentStage pointer. Use with care.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StageName)

    if ($StageName -notin $Script:STAGE_ORDER) {
        throw "Unknown stage '$StageName'. Valid stages: $($Script:STAGE_ORDER -join ', ')"
    }

    Assert-StateExists
    Invoke-WithFileLock {
        $state = Read-StateFile
        $state['CurrentStage']   = $StageName
        $state['LastUpdatedAt']  = (Get-Date -Format 'o')
        Write-StateFile -State $state
    }
}

function Get-CurrentStage {
    <#
    .SYNOPSIS
        Returns the name of the stage that should run next.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Assert-StateExists
    $state = Read-StateFile
    return $state['CurrentStage']
}

function Set-DeployComplete {
    <#
    .SYNOPSIS
        Marks the entire deployment as finished.
    #>
    [CmdletBinding()]
    param()

    Assert-StateExists
    Invoke-WithFileLock {
        $state = Read-StateFile
        $state['DeployComplete']     = $true
        $state['DeployCompletedAt']  = (Get-Date -Format 'o')
        $state['LastUpdatedAt']      = (Get-Date -Format 'o')
        Write-StateFile -State $state
    }
    Write-Verbose "[State] Deployment marked as complete."
}

function Test-DeployComplete {
    <#
    .SYNOPSIS
        Returns $true if the entire deployment has been marked complete.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-Path $Script:STATE_FILE)) { return $false }
    $state = Read-StateFile
    return [bool]$state['DeployComplete']
}

function Write-StateError {
    <#
    .SYNOPSIS
        Records an error against a stage without marking the deployment failed.
        The orchestrator decides whether to retry or abort based on config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageName,
        [Parameter(Mandatory)][string]$ErrorMessage
    )

    Assert-StateExists
    Invoke-WithFileLock {
        $state = Read-StateFile
        $state['LastError']          = $ErrorMessage
        $state['LastErrorStage']     = $StageName
        $state['LastErrorTimestamp'] = (Get-Date -Format 'o')
        $state['LastUpdatedAt']      = (Get-Date -Format 'o')

        # Track which stages have ever had errors (for reporting)
        if ($state['FailedStages'] -notcontains $StageName) {
            $state['FailedStages'] = @($state['FailedStages']) + $StageName
        }

        Write-StateFile -State $state
    }
}

function Add-RebootCount {
    <#
    .SYNOPSIS
        Increments the reboot counter. Called by the orchestrator before
        issuing a Restart-Computer.
    #>
    [CmdletBinding()]
    param()

    Assert-StateExists
    Invoke-WithFileLock {
        $state = Read-StateFile
        $count = [int]$state['RebootCount'] + 1
        $state['RebootCount']   = $count
        $state['LastUpdatedAt'] = (Get-Date -Format 'o')
        Write-StateFile -State $state
    }
}

function Get-StageStatus {
    <#
    .SYNOPSIS
        Returns a formatted summary of all stage statuses for logging/display.
    #>
    [CmdletBinding()]
    param()

    Assert-StateExists
    $state = Read-StateFile

    $rows = foreach ($stage in $Script:STAGE_ORDER) {
        if ($state['CompletedStages'] -contains $stage) {
            $status = 'COMPLETE'
            $ts     = $state['StageTimestamps'][$stage]
        } elseif ($state['FailedStages'] -contains $stage) {
            $status = 'FAILED'
            $ts     = $state['LastErrorTimestamp']
        } elseif ($state['CurrentStage'] -eq $stage) {
            $status = 'PENDING (next)'
            $ts     = ''
        } else {
            $status = 'waiting'
            $ts     = ''
        }

        [PSCustomObject]@{
            Stage     = $stage
            Status    = $status
            Timestamp = $ts
        }
    }

    return $rows
}

function Reset-DeployState {
    <#
    .SYNOPSIS
        DESTRUCTIVE - Deletes the state file. For testing/development only.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Force)

    if (-not $Force -and -not $PSCmdlet.ShouldProcess($Script:STATE_FILE, 'Delete state file')) {
        return
    }
    Remove-Item -Path $Script:STATE_FILE -Force -ErrorAction SilentlyContinue
    Write-Warning "[State] State file deleted. Run bootstrap.ps1 to restart deployment."
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
Export-ModuleMember -Function @(
    'Initialize-DeployState'
    'Get-DeployState'
    'Save-DeployState'
    'Set-StageComplete'
    'Test-StageComplete'
    'Set-CurrentStage'
    'Get-CurrentStage'
    'Set-DeployComplete'
    'Test-DeployComplete'
    'Write-StateError'
    'Add-RebootCount'
    'Get-StageStatus'
    'Reset-DeployState'
    'ConvertTo-Hashtable'
)
