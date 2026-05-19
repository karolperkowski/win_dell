#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy forensics collector. Bundles state, logs, hardware info, and
    live daemon state into a dated per-machine archive folder, and appends a
    run entry to a per-machine manifest.json so multiple deploys on the same
    machine are easy to track over time.

.DESCRIPTION
    Output layout under <ForensicsRoot>:

        <ForensicsRoot>\
          <hostname>\
            manifest.json
            runs\
              20260519-134500-cleanup\
                state.json
                tailscale.json           (redacted)
                tailscale-live.json
                VERSION
                settings.json            (redacted copy)
                hardware.json
                tools-versions.txt
                powercfg-active.txt
                powercfg-query.txt
                scheduled-tasks.txt
                system-errors.txt
                auto-snapshot-<ts>.txt   (from Troubleshoot.ps1 -Action Status)
                run-summary.json
                logs\
                  bootstrap.log
                  session.log
                  *.log
              20260520-091211-manual\
                ...

    Root-directory resolution (in order):
      1. -ForensicsRoot parameter (verbatim)
      2. Forensics.Root from settings.json (if non-null)
      3. D:\WinDeploy-Forensics if D:\ exists and a sentinel file can be
         created
      4. C:\WinDeploy-Forensics as a last resort

    Collection failures are non-fatal: every step is wrapped in its own
    try/catch, missing files become WARN lines, and the manifest is updated
    even if parts of the collection were incomplete.

.PARAMETER ForensicsRoot
    Explicit override for the archive root. Skips auto-detect.

.PARAMETER Reason
    Free-text reason string. Appears in the run folder name (sanitized) and
    in the manifest entry. Default 'manual'.

.PARAMETER Trigger
    Who invoked the tool: 'cli', 'cleanup-stage-tail', 'orchestrator-fatal',
    etc. Default 'cli'.

.PARAMETER Zip
    Also produce a .zip alongside the run folder.

.PARAMETER NoManifest
    Skip manifest append. Used by tests.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Collect-Forensics.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Collect-Forensics.ps1 `
        -Reason 'post-upgrade-smoke' -Zip
#>

[CmdletBinding()]
param(
    [string]$ForensicsRoot,
    [string]$Reason  = 'manual',
    [string]$Trigger = 'cli',
    [switch]$Zip,
    [switch]$NoManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Resolve WinDeploy paths (Config.psm1 optional, mirrors Troubleshoot.ps1).
# ---------------------------------------------------------------------------
$Script:DeployRoot   = 'C:\ProgramData\WinDeploy'
$Script:RepoDir      = Join-Path $Script:DeployRoot 'repo'
$Script:LogDir       = Join-Path $Script:DeployRoot 'Logs'
$Script:StateFile    = Join-Path $Script:DeployRoot 'state.json'
$Script:TsJsonFile   = Join-Path $Script:DeployRoot 'tailscale.json'
$Script:SettingsFile = Join-Path $Script:RepoDir 'config\settings.json'

$configPath = Join-Path $Script:RepoDir 'core\Config.psm1'
if (Test-Path $configPath) {
    try {
        Import-Module $configPath -DisableNameChecking -Force
        $wd = Get-WDConfig
        if ($wd) {
            $Script:DeployRoot   = $wd.DeployRoot
            $Script:RepoDir      = $wd.RepoDir
            $Script:LogDir       = $wd.LogDir
            $Script:StateFile    = $wd.StateFile
            $Script:TsJsonFile   = $wd.TailscaleJson
            $Script:SettingsFile = Join-Path $wd.RepoDir 'config\settings.json'
        }
    } catch {
        Write-Warning "Config.psm1 import failed; using fallback paths. $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Read Forensics.* config from settings.json (best-effort).
# ---------------------------------------------------------------------------
$Script:RedactKeys = @('AuthKey','Password','Secret','Token','ApiKey','PrivateKey','ConnectionString')
$Script:AutoZip    = $false
$Script:RootFromConfig = $null
if (Test-Path $Script:SettingsFile) {
    try {
        $cfg = Get-Content $Script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains 'Forensics' -and $cfg.Forensics) {
            $f = $cfg.Forensics
            if ($f.PSObject.Properties.Name -contains 'Root' -and $f.Root) {
                $Script:RootFromConfig = [string]$f.Root
            }
            if ($f.PSObject.Properties.Name -contains 'AutoZip' -and $f.AutoZip -eq $true) {
                $Script:AutoZip = $true
            }
            if ($f.PSObject.Properties.Name -contains 'RedactKeys' -and $f.RedactKeys) {
                $Script:RedactKeys = @($f.RedactKeys)
            }
        }
    } catch {
        Write-Warning "Could not read Forensics config from settings.json: $($_.Exception.Message)"
    }
}

if ($Zip) { $Script:AutoZip = $true }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-SanitizedName {
    param([string]$Value)
    if (-not $Value) { return 'unknown' }
    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Test-DriveWritable {
    <#
    Returns $true if a sentinel file can be created at the supplied root.
    Catches read-only / CD-ROM / locked USB drives that pass Test-Path but
    fail the first write.
    #>
    param([string]$Root)
    if (-not (Test-Path $Root)) { return $false }
    $sentinel = Join-Path $Root ('.windeploy-write-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        New-Item -ItemType File -Path $sentinel -Force -ErrorAction Stop | Out-Null
        Remove-Item -Path $sentinel -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Resolve-ForensicsRoot {
    <#
    Order: -ForensicsRoot > Forensics.Root config > D:\WinDeploy-Forensics
           (if writable) > C:\WinDeploy-Forensics.
    Returns @{ Root; FellBackToC }.
    #>
    if ($ForensicsRoot) {
        return @{ Root = $ForensicsRoot; FellBackToC = $false }
    }
    if ($Script:RootFromConfig) {
        return @{ Root = $Script:RootFromConfig; FellBackToC = $false }
    }
    if (Test-DriveWritable 'D:\') {
        return @{ Root = 'D:\WinDeploy-Forensics'; FellBackToC = $false }
    }
    Write-Warning 'D:\ is missing or not writable. Falling back to C:\WinDeploy-Forensics.'
    return @{ Root = 'C:\WinDeploy-Forensics'; FellBackToC = $true }
}

function Invoke-Step {
    <#
    Wraps each collection step so a single failure becomes a logged warning
    rather than aborting the whole run. Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Block
    )
    try {
        & $Block
        Write-Host "  [OK ] $Label" -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Host "  [SKIP] $Label -- $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Redact-JsonText {
    <#
    Regex-based redaction of string values for any property whose name
    matches one of the configured redact keys (case-insensitive). Only
    targets string values -- objects, numbers, and booleans are not
    touched. The match is intentionally non-greedy to avoid swallowing
    multiple keys on the same line.
    #>
    param([string]$JsonText, [string[]]$Keys)

    if ([string]::IsNullOrEmpty($JsonText)) { return $JsonText }
    $out = $JsonText
    foreach ($k in $Keys) {
        $esc = [regex]::Escape($k)
        $pattern = '"(?i)' + $esc + '"\s*:\s*"((?:\\.|[^"\\])*)"'
        $out = [regex]::Replace($out, $pattern, {
            param($m)
            $val = $m.Groups[1].Value
            $len = $val.Length
            return '"' + $k + '": "<redacted len=' + $len + '>"'
        })
    }
    return $out
}

function Save-RedactedJsonFile {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path $Source)) { throw "Source not found: $Source" }
    $text = Get-Content $Source -Raw -Encoding UTF8
    $redacted = Redact-JsonText -JsonText $text -Keys $Script:RedactKeys
    [System.IO.File]::WriteAllText($Destination, $redacted, [System.Text.UTF8Encoding]::new($false))
}

function Use-FileLock {
    <#
    Acquires an exclusive lock on a sentinel file and runs the supplied
    scriptblock. Used to serialise manifest.json writes when both the
    Cleanup stage and a manual run might fire close in time.
    #>
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][scriptblock]$Block,
        [int]$MaxAttempts = 8,
        [int]$BackoffMs   = 250
    )
    $stream = $null
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        try {
            $stream = [System.IO.File]::Open($LockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            break
        } catch {
            Start-Sleep -Milliseconds ($BackoffMs * ($i + 1))
        }
    }
    if (-not $stream) {
        throw "Could not acquire manifest lock at $LockPath after $MaxAttempts attempts."
    }
    try {
        & $Block
    } finally {
        $stream.Dispose()
        Remove-Item -Path $LockPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-DeployStateSnapshot {
    <#
    Reads state.json and returns a PSCustomObject summary used by both
    run-summary.json and manifest.json.
    #>
    if (-not (Test-Path $Script:StateFile)) { return $null }
    try {
        return Get-Content $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "state.json parse failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-StageOutcomes {
    param($State)
    $outcomes = [ordered]@{}
    if (-not $State) { return $outcomes }

    $completed = @()
    if ($State.PSObject.Properties.Name -contains 'CompletedStages' -and $State.CompletedStages) {
        $completed = @($State.CompletedStages)
    }
    $failed = @()
    if ($State.PSObject.Properties.Name -contains 'FailedStages' -and $State.FailedStages) {
        $failed = @($State.FailedStages)
    }
    $current = ''
    if ($State.PSObject.Properties.Name -contains 'CurrentStage' -and $State.CurrentStage) {
        $current = [string]$State.CurrentStage
    }

    $stages = @()
    if ($wd -and $wd.StageOrder) { $stages = @($wd.StageOrder) }
    else {
        # Fallback list if Config.psm1 was unavailable.
        $stages = @('TimeSync','PowerSettings','Debloat','WinTweaks',
                    'InstallDellSupportAssist','InstallDellPowerManager',
                    'ConfigureDellUpdates','InstallRustDesk','InstallTailscale',
                    'RemoteAccess','WindowsUpdate','Cleanup')
    }

    foreach ($s in $stages) {
        if ($failed -contains $s)            { $outcomes[$s] = 'Failed';   continue }
        if ($completed -contains $s)         { $outcomes[$s] = 'Complete'; continue }
        if ($current -eq $s)                 { $outcomes[$s] = 'InProgress'; continue }
        $outcomes[$s] = 'NotRun'
    }
    return $outcomes
}

function Get-OverallOutcome {
    param($State)
    if (-not $State) { return 'unknown' }
    $deployComplete = $false
    if ($State.PSObject.Properties.Name -contains 'DeployComplete') {
        $deployComplete = [bool]$State.DeployComplete
    }
    $failedCount = 0
    if ($State.PSObject.Properties.Name -contains 'FailedStages' -and $State.FailedStages) {
        $failedCount = @($State.FailedStages).Count
    }
    $lastError = $null
    if ($State.PSObject.Properties.Name -contains 'LastError') {
        $lastError = $State.LastError
    }

    if ($deployComplete -and $failedCount -eq 0) { return 'success' }
    if ($deployComplete -and $failedCount -gt 0) { return 'partial' }
    if (-not $deployComplete -and $lastError)    { return 'failure' }
    return 'in-progress'
}

function Get-VersionStamp {
    $vf = Join-Path $Script:RepoDir 'VERSION'
    if (-not (Test-Path $vf)) { return $null }
    $text = (Get-Content $vf -Raw -Encoding UTF8).Trim()
    $info = @{ raw = $text; sha = $null; branch = $null }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*commit\s*[:=]\s*([0-9a-f]+)') { $info.sha    = $Matches[1] }
        if ($line -match '^\s*branch\s*[:=]\s*(\S+)')        { $info.branch = $Matches[1] }
    }
    return $info
}

function Get-MachineFacts {
    $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS           -ErrorAction SilentlyContinue
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $mfg = ''; $model = ''; $biosVer = ''; $serial = ''
    $osCaption = ''; $osBuild = ''
    if ($cs)   { $mfg = $cs.Manufacturer; $model = $cs.Model }
    if ($bios) { $biosVer = $bios.SMBIOSBIOSVersion; $serial = $bios.SerialNumber }
    if ($os)   { $osCaption = $os.Caption; $osBuild = $os.BuildNumber }
    return [PSCustomObject]@{
        manufacturer = "$mfg"
        model        = "$model"
        serial       = "$serial"
        bios_version = "$biosVer"
        os_caption   = "$osCaption"
        os_build     = "$osBuild"
    }
}

function Get-ElapsedMinutes {
    param($State)
    if (-not $State) { return $null }
    $start = $null; $end = $null
    if ($State.PSObject.Properties.Name -contains 'BootstrappedAt' -and $State.BootstrappedAt) {
        try { $start = [datetime]::Parse($State.BootstrappedAt).ToUniversalTime() } catch { }
    }
    if ($State.PSObject.Properties.Name -contains 'DeployCompletedAt' -and $State.DeployCompletedAt) {
        try { $end = [datetime]::Parse($State.DeployCompletedAt).ToUniversalTime() } catch { }
    }
    if (-not $end -and $State.PSObject.Properties.Name -contains 'LastUpdatedAt' -and $State.LastUpdatedAt) {
        try { $end = [datetime]::Parse($State.LastUpdatedAt).ToUniversalTime() } catch { }
    }
    if (-not $start -or -not $end) { return $null }
    return [math]::Round(($end - $start).TotalMinutes, 1)
}

# ---------------------------------------------------------------------------
# Collection steps
# ---------------------------------------------------------------------------

function Copy-StateFile {
    param([string]$RunDir)
    if (-not (Test-Path $Script:StateFile)) { throw "state.json not found at $Script:StateFile" }
    Copy-Item -Path $Script:StateFile -Destination (Join-Path $RunDir 'state.json') -Force
}

function Copy-Logs {
    param([string]$RunDir)
    if (-not (Test-Path $Script:LogDir)) { throw "LogDir not found: $Script:LogDir" }
    $dest = Join-Path $RunDir 'logs'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $Script:LogDir '*') -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
}

function Copy-TailscaleJson {
    param([string]$RunDir)
    if (-not (Test-Path $Script:TsJsonFile)) { throw "tailscale.json not found at $Script:TsJsonFile" }
    Save-RedactedJsonFile -Source $Script:TsJsonFile -Destination (Join-Path $RunDir 'tailscale.json')
}

function Save-TailscaleLive {
    param([string]$RunDir)
    $exe = 'C:\Program Files\Tailscale\tailscale.exe'
    if (-not (Test-Path $exe)) { throw "tailscale.exe not installed at $exe" }
    $captured = @(& $exe status --json 2>&1)
    $text = ($captured -join "`n")
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'tailscale-live.json'), $text, [System.Text.UTF8Encoding]::new($false))
}

function Copy-Version {
    param([string]$RunDir)
    $vf = Join-Path $Script:RepoDir 'VERSION'
    if (-not (Test-Path $vf)) { throw "VERSION not found at $vf" }
    Copy-Item -Path $vf -Destination (Join-Path $RunDir 'VERSION') -Force
}

function Copy-Settings {
    param([string]$RunDir)
    if (-not (Test-Path $Script:SettingsFile)) { throw "settings.json not found at $Script:SettingsFile" }
    Save-RedactedJsonFile -Source $Script:SettingsFile -Destination (Join-Path $RunDir 'settings.json')
}

function Invoke-TroubleshootSnapshot {
    param([string]$RunDir)
    $tool = Join-Path $Script:RepoDir 'tools\Troubleshoot.ps1'
    if (-not (Test-Path $tool)) { throw "Troubleshoot.ps1 not found at $tool" }
    $captured = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool `
        -Action Status -OutDir $RunDir -Reason "forensics-$Reason" 2>&1)
    # Output not required, but log it to stdout for visibility.
    foreach ($line in $captured) {
        if ($null -ne $line) {
            $s = "$line".Trim()
            if ($s) { Write-Host "    troubleshoot: $s" -ForegroundColor DarkGray }
        }
    }
}

function Save-PowercfgActive {
    param([string]$RunDir)
    $captured = @(& powercfg.exe /getactivescheme 2>&1)
    $text = ($captured -join "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'powercfg-active.txt'), $text, [System.Text.UTF8Encoding]::new($false))
}

function Save-PowercfgQuery {
    param([string]$RunDir)
    $captured = @(& powercfg.exe /getactivescheme 2>&1)
    $line = ($captured -join "`n")
    $guid = $null
    if ($line -match 'GUID:\s+([0-9a-f-]{36})') { $guid = $Matches[1] }
    if (-not $guid) { throw 'Could not determine active scheme GUID.' }

    $out = New-Object System.Text.StringBuilder
    foreach ($sub in '238c9fa8-0aad-41ed-83f4-97be242c8f20',
                     '7516b95f-f776-4464-8c53-06167f40cc99',
                     '4f971e89-eebd-4455-a8de-9e59040e7347') {
        $null = $out.AppendLine("--- subgroup $sub ---")
        $captured = @(& powercfg.exe /query $guid $sub 2>&1)
        foreach ($l in $captured) { $null = $out.AppendLine("$l") }
        $null = $out.AppendLine('')
    }
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'powercfg-query.txt'), $out.ToString(), [System.Text.UTF8Encoding]::new($false))
}

function Save-ScheduledTasks {
    param([string]$RunDir)
    $names = @('WinDeploy-Resume','WinDeploy-Monitor','WinDeploy-Notify',
               'WinDeploy-AutoLogonSafety','WinDeploy-Watchdog',
               'WinDeploy DCU Weekly Sweep')
    $lines = @()
    foreach ($n in $names) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if (-not $t) {
            $lines += "$n : NOT REGISTERED"
            continue
        }
        $info = Get-ScheduledTaskInfo -TaskName $n -ErrorAction SilentlyContinue
        $last = 'n/a'; $next = 'n/a'; $lastResult = 'n/a'
        if ($info) {
            if ($info.LastRunTime)   { $last = $info.LastRunTime }
            if ($info.NextRunTime)   { $next = $info.NextRunTime }
            if ($null -ne $info.LastTaskResult) { $lastResult = $info.LastTaskResult }
        }
        $lines += "$n : State=$($t.State)  LastRun=$last  NextRun=$next  LastResult=$lastResult"
    }
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'scheduled-tasks.txt'), ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

function Save-Hardware {
    param([string]$RunDir, $MachineFacts)
    $json = $MachineFacts | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'hardware.json'), $json, [System.Text.UTF8Encoding]::new($false))
}

function Save-ToolVersions {
    param([string]$RunDir)
    $lines = @()
    foreach ($tool in @(
        @{ Name = 'winget';    Cmd = 'winget.exe';     Args = @('--version') },
        @{ Name = 'tailscale'; Cmd = 'C:\Program Files\Tailscale\tailscale.exe'; Args = @('version') },
        @{ Name = 'dcu-cli';   Cmd = 'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe'; Args = @('/version') }
    )) {
        try {
            if (Test-Path $tool.Cmd) {
                $captured = @(& $tool.Cmd @($tool.Args) 2>&1)
                $lines += "$($tool.Name): $($captured -join ' | ')"
            } else {
                # Try via PATH (winget normally resolves via PATH).
                $cmd = Get-Command $tool.Cmd -ErrorAction SilentlyContinue
                if ($cmd) {
                    $captured = @(& $cmd.Source @($tool.Args) 2>&1)
                    $lines += "$($tool.Name): $($captured -join ' | ')"
                } else {
                    $lines += "$($tool.Name): NOT INSTALLED"
                }
            }
        } catch {
            $lines += "$($tool.Name): ERROR -- $($_.Exception.Message)"
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'tools-versions.txt'), ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

function Save-SystemErrors {
    param([string]$RunDir)
    $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2 } -MaxEvents 50 -ErrorAction SilentlyContinue)
    $lines = @()
    foreach ($e in $evts) {
        $lines += "{0:s}Z  L{1}  {2}/{3}  {4}" -f $e.TimeCreated.ToUniversalTime(), $e.Level, $e.ProviderName, $e.Id, ($e.Message -replace "`r?`n", ' ')
    }
    if ($lines.Count -eq 0) { $lines = @('No recent ERROR or CRITICAL System events.') }
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'system-errors.txt'), ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

function Save-RunSummary {
    param([string]$RunDir, $State, $MachineFacts, $VersionInfo, [string]$Outcome,
          [hashtable]$RootInfo, [int]$FilesCollected, [int64]$BytesCollected, [string]$RunSubdir)

    $stageOutcomes = Get-StageOutcomes -State $State
    $elapsed = Get-ElapsedMinutes -State $State

    $stageExtras = @{}
    if ($State -and $State.PSObject.Properties.Name -contains 'StageExtras' -and $State.StageExtras) {
        foreach ($p in $State.StageExtras.PSObject.Properties) {
            $stageExtras[$p.Name] = $p.Value
        }
    }

    $deployBlock = [ordered]@{
        current_stage         = if ($State) { "$($State.CurrentStage)" } else { $null }
        deploy_complete       = if ($State -and $State.PSObject.Properties.Name -contains 'DeployComplete') { [bool]$State.DeployComplete } else { $false }
        reboot_count          = if ($State -and $State.PSObject.Properties.Name -contains 'RebootCount') { [int]$State.RebootCount } else { 0 }
        completed_stages      = if ($State -and $State.CompletedStages) { @($State.CompletedStages) } else { @() }
        failed_stages         = if ($State -and $State.FailedStages) { @($State.FailedStages) } else { @() }
        last_error            = if ($State) { $State.LastError } else { $null }
        last_error_stage      = if ($State -and $State.PSObject.Properties.Name -contains 'LastErrorStage') { $State.LastErrorStage } else { $null }
        last_error_timestamp  = if ($State -and $State.PSObject.Properties.Name -contains 'LastErrorTimestamp') { $State.LastErrorTimestamp } else { $null }
        version_sha           = if ($VersionInfo) { $VersionInfo.sha } else { $null }
        version_branch        = if ($VersionInfo) { $VersionInfo.branch } else { $null }
        elapsed_minutes       = $elapsed
        outcome               = $Outcome
    }

    $summary = [ordered]@{
        schema_version = 1
        hostname       = $env:COMPUTERNAME
        machine        = $MachineFacts
        run = [ordered]@{
            timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
            reason               = $Reason
            trigger              = $Trigger
            forensics_root       = $RootInfo.Root
            fell_back_to_c_drive = $RootInfo.FellBackToC
            run_dir              = $RunSubdir
        }
        deploy          = $deployBlock
        stage_outcomes  = $stageOutcomes
        stage_extras    = $stageExtras
        files_collected = $FilesCollected
        bytes_collected = $BytesCollected
    }
    $json = $summary | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'run-summary.json'), $json, [System.Text.UTF8Encoding]::new($false))
    return $summary
}

function Update-Manifest {
    param(
        [string]$ManifestPath,
        [object]$Summary,
        [string]$RunSubdir
    )
    if ($NoManifest) { return }
    $lockPath = "$ManifestPath.lock"
    Use-FileLock -LockPath $lockPath -Block {
        $manifest = $null
        if (Test-Path $ManifestPath) {
            try {
                $manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                Write-Warning "Existing manifest unparseable; starting a fresh one. ($($_.Exception.Message))"
                $manifest = $null
            }
        }
        if (-not $manifest) {
            $manifest = [PSCustomObject]@{
                schema_version = 1
                hostname       = $env:COMPUTERNAME
                machine        = $Summary.machine
                first_run_utc  = $Summary.run.timestamp_utc
                last_run_utc   = $Summary.run.timestamp_utc
                runs           = @()
            }
        }

        $entry = [PSCustomObject]@{
            timestamp_utc   = $Summary.run.timestamp_utc
            reason          = $Summary.run.reason
            trigger         = $Summary.run.trigger
            outcome         = $Summary.deploy.outcome
            version_sha     = $Summary.deploy.version_sha
            elapsed_minutes = $Summary.deploy.elapsed_minutes
            failed_stages   = $Summary.deploy.failed_stages
            run_dir         = ($RunSubdir -replace '\\','/')
        }

        $runs = @()
        if ($manifest.PSObject.Properties.Name -contains 'runs' -and $manifest.runs) {
            $runs = @($manifest.runs)
        }
        $runs += $entry

        $updated = [PSCustomObject]@{
            schema_version = 1
            hostname       = $env:COMPUTERNAME
            machine        = $Summary.machine
            first_run_utc  = if ($manifest.PSObject.Properties.Name -contains 'first_run_utc' -and $manifest.first_run_utc) { $manifest.first_run_utc } else { $Summary.run.timestamp_utc }
            last_run_utc   = $Summary.run.timestamp_utc
            runs           = $runs
        }
        $json = $updated | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($ManifestPath, $json, [System.Text.UTF8Encoding]::new($false))
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$startTime = Get-Date
$rootInfo  = Resolve-ForensicsRoot
$root      = $rootInfo.Root
$hostName  = Get-SanitizedName -Value $env:COMPUTERNAME
$hostDir   = Join-Path $root $hostName
$runsDir   = Join-Path $hostDir 'runs'
$ts        = $startTime.ToString('yyyyMMdd-HHmmss')
$reasonSlug = Get-SanitizedName -Value $Reason
$runName   = "$ts-$reasonSlug"
$runDir    = Join-Path $runsDir $runName

if (-not (Test-Path $runDir)) {
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
}

$fallbackTag = ''
if ($rootInfo.FellBackToC) { $fallbackTag = '  (fell back from D:)' }

Write-Host ''
Write-Host "WinDeploy forensics collection" -ForegroundColor Cyan
Write-Host "  Host    : $env:COMPUTERNAME"
Write-Host "  Reason  : $Reason"
Write-Host "  Trigger : $Trigger"
Write-Host "  Root    : $root$fallbackTag"
Write-Host "  RunDir  : $runDir"
Write-Host ''

# Stage a copy of this script under <root>\bin so the tool sits next to its
# output. The repo copy at C:\ProgramData\WinDeploy\repo\tools\ remains the
# canonical entry point; the <root>\bin copy is a refreshed-every-run
# derivative that survives a C:\ reimage. Non-fatal -- a copy failure does
# not abort the rest of the collection.
Invoke-Step "self-copy to $($rootInfo.Root)\bin" {
    $binDir = Join-Path $rootInfo.Root 'bin'
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    $dest = Join-Path $binDir 'Collect-Forensics.ps1'
    Copy-Item -Path $PSCommandPath -Destination $dest -Force
} | Out-Null

# Collection steps (each step is non-fatal).
Invoke-Step 'state.json'                  { Copy-StateFile          -RunDir $runDir } | Out-Null
Invoke-Step 'logs/'                       { Copy-Logs               -RunDir $runDir } | Out-Null
Invoke-Step 'tailscale.json (redacted)'   { Copy-TailscaleJson      -RunDir $runDir } | Out-Null
Invoke-Step 'tailscale-live.json'         { Save-TailscaleLive      -RunDir $runDir } | Out-Null
Invoke-Step 'VERSION'                     { Copy-Version            -RunDir $runDir } | Out-Null
Invoke-Step 'settings.json (redacted)'    { Copy-Settings           -RunDir $runDir } | Out-Null
Invoke-Step 'Troubleshoot Status snapshot' { Invoke-TroubleshootSnapshot -RunDir $runDir } | Out-Null
Invoke-Step 'powercfg-active'             { Save-PowercfgActive     -RunDir $runDir } | Out-Null
Invoke-Step 'powercfg-query'              { Save-PowercfgQuery      -RunDir $runDir } | Out-Null
Invoke-Step 'scheduled-tasks'             { Save-ScheduledTasks     -RunDir $runDir } | Out-Null
Invoke-Step 'system-errors'               { Save-SystemErrors       -RunDir $runDir } | Out-Null

# Hardware facts are computed once (also used in summary + manifest).
$machineFacts = $null
Invoke-Step 'hardware.json' {
    $script:machineFacts = Get-MachineFacts
    Save-Hardware -RunDir $runDir -MachineFacts $script:machineFacts
} | Out-Null
if (-not $machineFacts) { $machineFacts = Get-MachineFacts }

Invoke-Step 'tools-versions'              { Save-ToolVersions       -RunDir $runDir } | Out-Null

# Tally files + bytes.
$collected = @(Get-ChildItem -Path $runDir -Recurse -File -ErrorAction SilentlyContinue)
$fileCount = $collected.Count
$byteCount = 0
foreach ($f in $collected) { $byteCount += $f.Length }

# Run summary + manifest append.
$state       = Get-DeployStateSnapshot
$versionInfo = Get-VersionStamp
$outcome     = Get-OverallOutcome -State $state
$runSubdir   = Join-Path (Join-Path $hostName 'runs') $runName

$summary = $null
$summary = Save-RunSummary -RunDir $runDir -State $state -MachineFacts $machineFacts `
                           -VersionInfo $versionInfo -Outcome $outcome `
                           -RootInfo $rootInfo -FilesCollected $fileCount -BytesCollected $byteCount `
                           -RunSubdir $runSubdir

$manifestPath = Join-Path $hostDir 'manifest.json'
try {
    Update-Manifest -ManifestPath $manifestPath -Summary $summary -RunSubdir $runSubdir
    Write-Host "  [OK ] manifest.json updated" -ForegroundColor DarkGray
} catch {
    Write-Host "  [SKIP] manifest.json update -- $($_.Exception.Message)" -ForegroundColor Yellow
}

# Optional zip.
if ($Script:AutoZip) {
    try {
        $zipPath = "$runDir.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zipPath -Force
        Write-Host "  [OK ] zip written: $zipPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "  [SKIP] zip -- $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-Host ''
Write-Host ("Forensics collected: $runDir") -ForegroundColor Green
Write-Host ("  outcome={0}  files={1}  bytes={2}  elapsed={3}s" -f $outcome, $fileCount, $byteCount, $elapsed)

# Function-style return value for callers that capture it.
return [PSCustomObject]@{
    Success        = $true
    RunDir         = $runDir
    ManifestPath   = $manifestPath
    Outcome        = $outcome
    FellBackToC    = $rootInfo.FellBackToC
    FilesCollected = $fileCount
    BytesCollected = $byteCount
}
