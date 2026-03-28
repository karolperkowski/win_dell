#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Logging Module

.DESCRIPTION
    Provides structured, timestamped logging to both the console and a per-stage
    log file. All log files land under C:\ProgramData\WinDeploy\Logs\.

    Log file naming: <stage>_<yyyyMMdd_HHmmss>.log
    A session-level log (session.log) captures everything across all stages.

.EXPORTED FUNCTIONS
    Initialize-Logger
    Write-Log          (alias: wlog)
    Write-LogInfo
    Write-LogSuccess
    Write-LogWarning
    Write-LogError
    Write-LogSection   (prints a visual divider for readability)
    Close-Logger
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------
$Script:LogDir      = 'C:\ProgramData\WinDeploy\Logs'
$Script:SessionLog  = $null    # Full path to the session-level log file
$Script:StageLog    = $null    # Full path to the current stage log file
$Script:StageName   = $null
$Script:Initialized = $false

# Console colour map
$Script:LevelColours = @{
    INFO    = 'Cyan'
    SUCCESS = 'Green'
    WARN    = 'Yellow'
    ERROR   = 'Red'
    SECTION = 'Magenta'
    DEBUG   = 'DarkGray'
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Initialize-Logger {
    <#
    .SYNOPSIS
        Sets up the logger for a named stage. Must be called before any
        Write-Log* calls within a stage script.

    .PARAMETER Stage
        Human-readable name of the stage (used in filename and log prefix).

    .PARAMETER LogDirectory
        Override the default log directory. Useful for testing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [string]$LogDirectory = $Script:LogDir
    )

    $Script:LogDir    = $LogDirectory
    $Script:StageName = $Stage

    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'

    # Session log persists across all stages; append to it
    $Script:SessionLog = Join-Path $Script:LogDir 'session.log'

    # Stage log is unique per stage invocation
    $Script:StageLog = Join-Path $Script:LogDir "${Stage}_${ts}.log"

    $Script:Initialized = $true

    Write-LogSection "Stage: $Stage"
    Write-LogInfo "Logger initialised. Stage log: $($Script:StageLog)"
    Write-LogInfo "OS: $($(Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-LogInfo "PowerShell: $($PSVersionTable.PSVersion)"
    Write-LogInfo "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
}

function Write-Log {
    <#
    .SYNOPSIS
        Core logging function. All other Write-Log* functions route through here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR','SECTION','DEBUG')]
        [string]$Level = 'INFO'
    )

    $ts      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $stage   = if ($Script:StageName) { "[$($Script:StageName)]" } else { '[WinDeploy]' }
    $logLine = "[$ts] [$Level] $stage $Message"

    # Console output with colour
    $colour = $Script:LevelColours[$Level]
    Write-Host $logLine -ForegroundColor $colour

    if ($Script:Initialized) {
        # Append to both stage log and session log
        foreach ($target in @($Script:StageLog, $Script:SessionLog)) {
            if ($target) {
                try {
                    Add-Content -Path $target -Value $logLine -Encoding UTF8
                } catch {
                    # Non-fatal: log write failure should not stop deployment
                    Write-Host "[LOGGER ERROR] Could not write to '$target': $_" -ForegroundColor Red
                }
            }
        }
    }
}

function Write-LogInfo    { param([string]$Message) Write-Log -Message $Message -Level 'INFO'    }
function Write-LogSuccess { param([string]$Message) Write-Log -Message $Message -Level 'SUCCESS' }
function Write-LogWarning { param([string]$Message) Write-Log -Message $Message -Level 'WARN'    }
function Write-LogError   { param([string]$Message) Write-Log -Message $Message -Level 'ERROR'   }
function Write-LogDebug   { param([string]$Message) Write-Log -Message $Message -Level 'DEBUG'   }

function Write-LogSection {
    <#
    Prints a bold visual divider to make stage transitions obvious in the log.
    #>
    param([string]$Title)
    $line    = '=' * 72
    $padding = ' ' * [Math]::Max(0, [Math]::Floor((72 - $Title.Length - 2) / 2))
    Write-Log -Message $line          -Level 'SECTION'
    Write-Log -Message "$padding $Title $padding" -Level 'SECTION'
    Write-Log -Message $line          -Level 'SECTION'
}

function Write-LogException {
    <#
    .SYNOPSIS
        Logs an exception object with full detail - message, type, and stack.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    Write-LogError "Exception: $($ErrorRecord.Exception.Message)"
    Write-LogError "Type: $($ErrorRecord.Exception.GetType().FullName)"
    Write-LogError "Location: $($ErrorRecord.InvocationInfo.PositionMessage)"
    if ($ErrorRecord.Exception.StackTrace) {
        Write-LogError "StackTrace:`n$($ErrorRecord.Exception.StackTrace)"
    }
}

function Close-Logger {
    <#
    .SYNOPSIS
        Writes a closing banner to the stage log. Call at the end of each stage.
    #>
    [CmdletBinding()]
    param([ValidateSet('SUCCESS','FAILED')][string]$FinalStatus = 'SUCCESS')

    $emoji = if ($FinalStatus -eq 'SUCCESS') { '[OK]' } else { '[!!]' }
    Write-LogSection "Stage '$($Script:StageName)' ended - $emoji $FinalStatus"
    $Script:StageLog  = $null
    $Script:StageName = $null
}

# Convenience alias
Set-Alias -Name wlog -Value Write-Log

Export-ModuleMember -Function @(
    'Initialize-Logger'
    'Write-Log'
    'Write-LogInfo'
    'Write-LogSuccess'
    'Write-LogWarning'
    'Write-LogError'
    'Write-LogDebug'
    'Write-LogSection'
    'Write-LogException'
    'Close-Logger'
) -Alias 'wlog'
