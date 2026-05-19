# CLAUDE.md

Context and conventions for AI-assisted development on this repo.

---

## What this repo is

`win_dell` is a fully unattended Windows 10/11 post-install automation framework for Dell hardware.
Target hardware: Dell laptops/desktops, Windows 10 21H2+ and Windows 11 22H2+.
**All code must run on Windows PowerShell 5.1.** PowerShell 7 is not assumed.

---

## Tooling

- `tools/Update-Index.ps1` -- regenerates `INDEX.md` (file inventory with annotations)
- `lint.ps1` -- PSScriptAnalyzer + custom PS 5.1 / task / path / state checks
- `.github/workflows/ci.yml` -- lint, validate tasks, sign manifest (runs on push to main)

---

## Repo layout

| File | Role |
| --- | --- |
| `install.ps1` | `irm\|iex` entry point -- downloads repo, verifies manifest, launches bootstrap |
| `bootstrap.ps1` | Sets up scheduled tasks, state, launches monitor + orchestrator |
| `core/Orchestrator.ps1` | Master controller -- runs stages in order, handles reboots |
| `core/Config.psm1` | Shared constants (`$WD.*`) -- single source of truth for all paths and stage order |

---

## PowerShell 5.1 rules -- enforce on every change

| Forbidden | PS 5.1 alternative |
| --- | --- |
| `$x ?? $y` | `if ($x) { $x } else { $y }` |
| `$x?.Prop` | `if ($x) { $x.Prop }` |
| `??=` | `if (-not $x) { $x = $y }` |
| `[array].Count` on pipeline result | `@($result).Count` |
| `ConvertFrom-Json -AsHashtable` | Gate behind `$PSVersionTable.PSVersion.Major -ge 6`, use `ConvertTo-Hashtable` shim on 5.1 |
| `Get-WindowsUpdate -AcceptAll` | `-AcceptAll` only valid on `Install-WindowsUpdate` |
| `trap { continue }` to skip failed assignment | Use `try/catch` -- `continue` resumes after the failed statement, not at the catch |
| `Add-Content` with concurrent SYSTEM writer | `[System.IO.File]::AppendAllText(path, text, UTF8)` |
| `CharacterSpacing` in WPF XAML | Silverlight-only -- not available in WPF, remove it |
| `-LogonType Interactive` with `-GroupId` | Incompatible parameter set -- omit `-LogonType` for group-based principals |
| `New-ScheduledTaskPrincipal -GroupId` + `-LogonType` | Invalid combination -- use one or the other |

---

## Shared constants -- always use $WD.*

`core/Config.psm1` exports `$WD`. Every script that needs a path or task name imports this:

```powershell
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -DisableNameChecking -Force
```

**Never hardcode `C:\ProgramData\WinDeploy` in a stage script.**
**Never duplicate the stage list -- it lives only in `Config.psm1`.**

Scripts that run before Config loads (bootstrap, install, uninstall, Resilience early log, Monitor pre-WPF) are permitted to hardcode the path as a fallback.

---

## Stage script return contract

Every stage script in `core/` runs in its own `Invoke-Stage` boundary and **must** return exactly one hashtable as its final pipeline output:

```powershell
return @{ Status = 'Complete';       Message = 'Human readable.' }
return @{ Status = 'RebootRequired'; Message = 'Why reboot needed.' }
return @{ Status = 'Failed';         Message = $_.Exception.Message }
```

**The single biggest footgun**: any other output that flows to the pipeline gets concatenated into an `Object[]` along with the hashtable, and the orchestrator rejects the whole thing with `Stage returned invalid result (type: Object[])`. Observed 2026-05-16 in `InstallTailscale` — inline `& winget ... 2>&1` merged winget's stdout into the script's return value. The rule:

- Native commands with `2>&1` must have their output captured into a variable (`$captured = @(& exe ... 2>&1)`) or piped to `Out-Null`/`ForEach-Object` — never left to flow.
- Use `Invoke-WingetCli` from `core/Winget.psm1` instead of inline `& winget` — it does this capture for you.
- Stage scripts must `return` exactly once, with a `@{ Status; Message }` hashtable. Never re-throw past the outer try.

Stages must **not** call `Restart-Computer` directly — return `RebootRequired` and let the orchestrator handle it.

---

## Stage pipeline order

`TimeSync > PowerSettings > Debloat > WinTweaks > InstallDellSupportAssist > InstallDellPowerManager > ConfigureDellUpdates > InstallRustDesk > InstallTailscale > RemoteAccess > WindowsUpdate > Cleanup`

`TimeSync` runs **first** because every downstream stage (TLS handshakes for winget, Windows Update token validation, code-signing checks, Tailscale auth) misbehaves with a skewed clock. On failure it returns `RebootRequired` (capped at `TimeSync_RebootRetryCount` < 2 via `StageExtras`) before giving up with `Failed`, so a fresh network stack gets a second chance. `TimeSync` is in both `REBOOT_ALLOWED_STAGES` and `DRAIN_STAGES` for this reason.

`PowerSettings` activates the Ultimate Performance plan (falls back to High Performance on Home SKUs where duplication is blocked) and pins display-off / sleep / hibernate / lid-close / sleep-button / power-button to Never / Do-nothing on both AC and DC. Settings live under `Stages.PowerSettings` in `config/settings.json` (`PowerPlan`, `DisableButtons`, `DisableSleepAndScreenOff`, `DisableHibernateFile`).

`ConfigureDellUpdates` runs after both Dell apps are installed but before `WindowsUpdate`. It applies best-effort SupportAssist auto-consent registry tweaks and registers a weekly SYSTEM-context `dcu-cli` sweep (default Sunday 03:00) so Dell BIOS/firmware/driver updates keep flowing after the one-shot deploy. The scheduled task reuses `Invoke-DellCommandUpdate` from [core/DellCommandUpdate.ps1](core/DellCommandUpdate.ps1) rather than re-implementing dcu-cli orchestration. Skips cleanly on non-Dell hardware. `ContinueOnError` defaults to true -- a failed SupportAssist registry write should never halt the deploy.

`RemoteAccess` runs after `InstallTailscale` so WinRM TrustedHosts can be scoped to the Tailscale CGNAT (`100.*`), and before `WindowsUpdate` so the machine remains remotely debuggable across the long update phase.

WindowsUpdate runs **last** because it takes the longest and requires multiple reboots.

---

## Logging

Use `Write-LogInfo`, `Write-LogSuccess`, `Write-LogWarning`, `Write-LogError` from `Logging.psm1`.
**Never use `Write-Host` in stage scripts -- it bypasses the log file.**
**Never use `Add-Content` for log writes -- use `[System.IO.File]::AppendAllText` to handle concurrent writers.**

---

## App install types (`AppInstall.ps1`)

Use `WINGET` when the package exists in the public `winget-pkgs` source. Use `WINGET_MANIFEST` when it doesn't (removed, private vendor, or you want to pin a specific URL). `WINGET_MANIFEST` generates a singleton YAML at install time from `PackageIdentifier`/`PackageVersion`/`Architecture`/`ManifestInstallerType`/`DownloadUrl`/`InstallerSha256` and hands it to `winget install --manifest` — winget still owns the download, SHA256 verification, silent handling, and exit codes. To bump a version, run `tools/Get-WingetManifestFields.ps1 -Url <new-url> -PackageIdentifier <id> -PackageVersion <ver>` to get the new SHA256 and paste it into `config/settings.json`. Never fall back to `MSI`/`EXE` when a `WINGET_MANIFEST` alternative works — we want one CLI owning all installs.

**Winget under SYSTEM context.** Microsoft does not officially support winget in the system context. We invoke it from SYSTEM anyway via the scheduled-task-driven orchestrator, with three hardening rules:

1. **Always pass `--source winget`.** The msstore source uses TLS certificate pinning that fails under SYSTEM with exit `-1978335138` (`0x8A15005E` = `APPINSTALLER_CLI_ERROR_PINNED_CERTIFICATE_MISMATCH`). Observed 2026-05-16 on RustDesk + Tailscale + Chrome simultaneously. Letting winget auto-pick the source resolves to msstore and every install fails in <1s. `WINGET_MANIFEST` installs (`winget install --manifest`) bypass source resolution entirely, so they don't need `--source`.
2. **Never call winget inline with `2>&1` redirection** in a script that has a `return` statement. The redirected stdout flows into the script's return pipeline and turns `@{Status='Failed'}` into `Object[]`, which the orchestrator rejects with "Stage returned invalid result (type: Object[])". Use `Invoke-WingetCli` from [core/Winget.psm1](core/Winget.psm1) — it captures output into a local variable so nothing leaks.
3. **Inspect winget exits via `Get-WingetExitMeaning`.** Raw codes like `-1978335138` are unreadable in logs. `core/Winget.psm1` maps the known codes to human-readable causes and writes them to `StageExtras`. Add new codes to `$Script:WINGET_EXIT_MEANINGS` as they show up in the wild.

The orchestrator runs `Test-WingetSourceHealth` once per deploy before any install stage and writes the result to `StageExtras.Orchestrator_WingetSource*`. If unhealthy, the install stages will fail individually but the cause is captured in a single legible place.

When `--source winget` still cannot get a package through (corporate proxy intercepting TLS, custom EDR re-signing certs), the escape hatches are: (a) move the package to `WINGET_MANIFEST` with a vendor URL + pinned SHA256, or (b) launch winget in the logged-in user's session via the same `Start-ProcessInUserSession` helper WinTweaks uses for WinUtil.

---

## Troubleshooting (`tools/Troubleshoot.ps1`)

Single entry point for diagnostics and recovery. Three actions:

```powershell
tools\Troubleshoot.ps1 -Action Status
tools\Troubleshoot.ps1 -Action Diagnose -Stage InstallTailscale
tools\Troubleshoot.ps1 -Action Repair   -Stage InstallTailscale
```

- **Status** is always safe (read-only). It writes a snapshot to `<LogDir>\auto-snapshot-<timestamp>[-<reason>].txt` containing state.json, tailscale.json, tail of task_resume.log, the latest per-stage log, live `tailscale status`, and the deployed VERSION. It also drops a pointer at `<LogDir>\latest-snapshot.path` which Monitor.ps1 surfaces in its UI.
- **Diagnose** runs a stage-specific read-only deep-dive.
- **Repair** runs a stage-specific destructive recovery. Tailscale's repair stops the resume task, kills hung `tailscale up` processes, hot-patches `core/Tailscale.ps1` from `main`, and restarts the resume task.

To add a new stage, extend `$Script:StagePlugins` in `tools/Troubleshoot.ps1` with a hashtable containing `Diagnose` and `Repair` scriptblocks.

### Auto-triggers — when things go south

`tools/Troubleshoot.ps1 -Action Status` is invoked automatically by:

1. **Orchestrator outer catch** on any FATAL throw (reason: `orchestrator-fatal`).
2. **Orchestrator halt path** when a stage fails and `ContinueOnError` is not set (reason: `halt-<stage>`).
3. **Orchestrator abort path** when `MAX_CONSECUTIVE_FAILURES` is hit (reason: `abort-<stage>`).
4. **Watchdog scheduled task** (every 30 min) before killing a >4h orchestrator (reason: `watchdog-kill-PID<n>`) and when it detects a stale stage — no `task_resume.log` activity for 20+ min while CurrentStage is neither `WindowsUpdate` nor `Cleanup` (reason: `watchdog-stale-<stage>`, idempotent via a sentinel file).

### Version stamping

`install.ps1` writes `<RepoDir>\VERSION` containing the commit SHA, branch, extract timestamp, and ZIP URL. The orchestrator logs every VERSION line at startup so log forensics can immediately tell which commit produced the observed behaviour. `bootstrap.ps1` warns loudly when the deployed VERSION is more than 7 days old — re-run `install.ps1` to refresh before assuming a bug is in current `main`.

---

## WinUtil direct-apply (WinTweaks Pass 1)

The WinTweaks stage's Pass 1 used to launch Chris Titus's WinUtil with `-Run -Noui` and let WinUtil's own runner apply the preset. **That path is broken for unattended use** and always timed out: `Invoke-WinUtilAutoRun` polls `$sync.ProcessRunning` (set true at the top of a background runspace, false only at the bottom). The runspace calls UI helpers like `Set-WinUtilProgressBar` which aren't defined in headless mode, so the flag stays true forever and the parent loops until the 12-minute kill. The GUI-with-auto-close-patch path had the same root cause via a different route. Observed 2026-04-10: both paths timed out on the first real-machine run, Pass 2 saved the stage.

**Current approach (since 2026-05-17):** Pass 1 downloads the WinUtil bundle, extracts the embedded `$sync.configs.tweaks` and `$sync.configs.feature` JSON heredocs by regex, and applies each preset ID's `registry` / `service` / `feature` / `InvokeScript` entries directly using our own helpers — synchronously, in our SYSTEM context, no GUI, no runspace, no dispatcher. The bundle URL list (`$Script:WinUtilBundleUrls` in `core/WinTweaks.ps1`) tries the GitHub release first, falls back to `christitus.com/win`.

**Why this is robust:**

1. WinUtil's `-Noui` runner is the broken part; the JSON tweak/feature definitions are not. We use the latter, ignore the former.
2. `HKCU:` paths in the bundle are rewritten to every mounted user hive (`Get-AllUserRoots`) — so per-user tweaks reach real users despite running as SYSTEM. Hives are mounted once in Main before both passes.
3. `Set-WinUtilServiceEntry` normalizes WinUtil's quirks: `"Disable"` (typo in their data) → `"Disabled"`, and `"AutomaticDelayedStart"` → `sc.exe config <svc> start= delayed-auto` (Set-Service's `-StartupType` doesn't accept it on PS 5.1).
4. `Enable-WinUtilWindowsFeature` uses `-NoRestart -All` so feature enables never trigger an out-of-band reboot — the orchestrator owns reboots.
5. `Invoke-WinUtilScriptEntry` runs each `InvokeScript` string in a try/catch and streams output through `Write-LogInfo`, so one bad script can't sink the whole pass.
6. `WPFInstall*` IDs are deliberately skipped — installs are owned by `data/profiles.json` + `Install-WingetApps`. If a re-exported preset includes installs they're ignored, not double-applied.

**`StageExtras` keys to inspect:**

| Key | Healthy value | What it tells you |
| --- | --- | --- |
| `WinTweaks_WinUtilOutcome` | `direct-apply` | Anything else (`skipped: preset missing`, `bundle-download-failed: ...`, `bundle-parse-failed: ...`) tells you why Pass 1 couldn't run |
| `WinTweaks_WinUtilPresetIdCount` | matches `config/winutil-preset.json` length | Total IDs parsed from the preset |
| `WinTweaks_WinUtilAppliedCount` | `PresetIdCount` minus skipped/unknown | IDs that resolved and were applied |
| `WinTweaks_WinUtilSkippedCount` | usually `0` | Count of `WPFInstall*` IDs skipped (installs are owned by `data/profiles.json`) |
| `WinTweaks_WinUtilUnknownPresetIds` | empty array | Anything listed here was renamed/removed upstream — refresh the preset |

**Verification commands** (run after WinTweaks has executed at least once):

```powershell
# All WinTweaks sub-status from the latest state.
Get-Content C:\ProgramData\WinDeploy\state.json -Raw |
    ConvertFrom-Json |
    Select-Object -ExpandProperty StageExtras |
    Format-List WinTweaks_*

# Per-tweak apply lines in the stage log.
Select-String -Path C:\ProgramData\WinDeploy\Logs\WinTweaks_*.log `
    -Pattern 'WinUtil direct apply|applying|unknown|InvokeScript'
```

**To refresh the preset:** run WinUtil interactively (`irm https://christitus.com/win | iex` from an elevated PowerShell), tick the desired Tweaks/Features, File menu → **Export Preset**, and overwrite `config/winutil-preset.json`. WinUtil's exporter writes UTF-16 LE with BOM — `Get-WinUtilPresetIds` uses `[System.IO.File]::ReadAllText` which auto-detects BOM, so no manual conversion. Both flat-array (`["WPFTweaksX",...]`) and nested-object (`{"WPFTweaks":[...],"WPFFeature":[...]}`) formats are accepted. After refreshing, run `tools/Test-WinUtilDirectApply.ps1` to confirm every preset ID still resolves against the current bundle (catches upstream renames before they hit production).

**Testing the direct-apply path:**

- `tools/Test-WinUtilDirectApply.ps1` — dry-run that downloads the bundle, parses configs, and reports what each preset ID would do (no writes). Use after re-exporting the preset or after a major WinUtil upstream change.
- `tools/Test-WinUtilApplyOne.ps1 [-TweakId WPFToggleDetailedBSoD]` — real-apply smoke test against a single preset ID. Snapshots the registry/service, applies, verifies, reverts. Use to validate the apply primitives on real hardware without triggering slow tweaks (cleanmgr, restore-point).

**Installs ownership:** installs (winget) are owned by `data/profiles.json` + `Install-WingetApps` in `WinTweaks.ps1`, not by WinUtil. If you re-export a preset, leave the WPFInstall section empty — even if present, Pass 1 will skip those IDs.

---

## Tailscale auth flow (`core/Tailscale.ps1`)

Tailscale registration races three outcomes against each other instead of waiting for an auth URL alone. Three failure modes the old single-signal wait could not distinguish:

- **Already-authed silent succeed**: `tailscale up` finds stored creds, succeeds without printing a URL.
- **Out-of-band sign-in**: the user authenticates through the Tailscale admin or a previously-printed URL; the daemon flips to `Running` while our wait loop watches stdout for a URL match that never comes.
- **URL format we don't match**: newer / enterprise control-plane URLs use `controlplane.tailscale.com` instead of `login.tailscale.com`.

The dual-condition wait loop exits on **URL captured** OR **`Test-TailscaleRegistered` returns true** OR **timeout**. If the daemon already shows `BackendState=Running` (pre-spawn check at the top of the stage), QR generation is skipped entirely. On timeout, every line captured from `tailscale up` is dumped to the log so the next failure is debuggable.

Thread-safety: `Start-TailscaleUp` writes captured URL + emitted lines into `[hashtable]::Synchronized(...)` so the async `add_OutputDataReceived` handler (runs on a .NET thread-pool thread) can safely communicate with the main polling loop. PS 5.1's `$script:`-scope assignment from event handlers is unreliable — observed silent stuck states.

**Pre-auth key path**: setting `Tailscale.AuthKey` in `config/settings.json` skips the QR entirely (`tailscale up --authkey=...`). Recommended for repeated unattended deploys.

---

## CI gotcha: INDEX.md self-reference

`INDEX.md` describes its own line count and byte size in its own entry. Writing `INDEX.md` changes both. The pre-commit hook regenerates **in a loop** (up to 5 iterations) until `git diff INDEX.md` is empty — without this loop, CI's "Verify INDEX.md is up to date" check fails on every push because the staged INDEX describes itself one revision stale. Converges in 1-2 iterations in practice.

Also: `Update-Index.ps1` excludes `.git/`, `.trunk/`, `.vscode/`, `.claude/`, `apps/<binaries>`, `logs/`, and `state.json`. CI uses a fresh checkout so the local-only `.trunk/` (trunk.io cache), `.vscode/`, and `.claude/` (Claude Code project settings) directories must be filtered to keep local and CI line counts equal.
