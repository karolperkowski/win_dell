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

`PowerSettings > Debloat > WinTweaks > InstallDellSupportAssist > InstallDellPowerManager > InstallRustDesk > InstallTailscale > RemoteAccess > WindowsUpdate > Cleanup`

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

## WinUtil outcome legibility (WinTweaks Pass 1)

The WinTweaks stage runs Chris Titus's WinUtil in Pass 1 against `config/winutil-preset.json`. Pass 2 (direct registry tweaks) always runs regardless — so an empty/silent WinUtil run will still leave WinTweaks marked SUCCESS. To distinguish "WinUtil applied N tweaks" from "WinUtil silently did nothing", the child script writes a transcript and a structured meta JSON; the parent ingests both. **Always check these on a real-machine run before concluding WinUtil worked.**

**Files produced per WinTweaks run** (one pair per orchestrator invocation, kept for post-mortem):

- `C:\ProgramData\WinDeploy\Logs\winutil-child-<guid>.log` — full transcript of the child PowerShell, including bundle download size, regex hit count, preset-vs-bundle ID diff, and exit code.
- `C:\ProgramData\WinDeploy\Logs\winutil-child-<guid>.meta.json` — structured outcome record.

**Verification commands** (run after WinTweaks has executed at least once):

```powershell
# All WinUtil sub-status from the latest state.
Get-Content C:\ProgramData\WinDeploy\state.json -Raw |
    ConvertFrom-Json |
    Select-Object -ExpandProperty StageExtras |
    Format-List WinTweaks_*

# Most recent child transcript.
Get-ChildItem C:\ProgramData\WinDeploy\Logs\winutil-child-*.log |
    Sort-Object LastWriteTime |
    Select-Object -Last 1 |
    Get-Content

# Summary lines in the main log.
Select-String -Path C:\ProgramData\WinDeploy\Logs\windeploy.log `
    -Pattern 'WinUtil outcome|Unknown preset|auto-close patch'
```

**`StageExtras` keys to inspect:**

| Key | Healthy value | What it tells you |
| --- | --- | --- |
| `WinTweaks_WinUtilLaunchMode` | `gui-autoclose` | `headless-noui` = no user session; `gui-patch-miss-headless-fallback` = upstream renamed `Invoke-WinUtilAutoRun`, regex needs an update |
| `WinTweaks_WinUtilAutoClosePatchHits` | `>= 1` | `0` means the regex matched no call sites — patched bundle was not used, headless `-Noui` ran instead |
| `WinTweaks_WinUtilPresetIdCount` | matches the preset file length | Total IDs read from `config/winutil-preset.json` |
| `WinTweaks_WinUtilKnownIdCount` | equal to `PresetIdCount` | IDs that exist in the live bundle |
| `WinTweaks_WinUtilUnknownPresetIds` | empty array | Anything listed here was silently dropped by WinUtil — upstream renamed an ID and the preset needs refreshing |
| `WinTweaks_WinUtilBundleIdCount` | several hundred (sanity) | If `0`, bundle-ID extraction regex failed — investigate the regex against the current bundle |
| `WinTweaks_WinUtilExitReason` | `gui-exit-0` | Anything else (`headless-inline-exit-...`, `exception: ...`) tells you which fallback path ran |

**To refresh the preset:** run WinUtil interactively (`irm https://christitus.com/win | iex` from an elevated PowerShell), tick the desired Tweaks/Features/Installs, File menu → **Export Preset**, and overwrite `config/winutil-preset.json`. WinUtil's exporter writes UTF-16 LE with BOM — the child reads via `[System.IO.File]::ReadAllText` which auto-detects BOM, so no manual conversion is needed. Both flat-array (`["WPFTweaksX",...]`) and nested-object (`{"WPFTweaks":[...],"WPFInstall":[...],"WPFFeature":[...]}`) formats are accepted.

**Installs ownership:** installs (winget) are owned by `data/profiles.json` + `Install-WingetApps` in `WinTweaks.ps1`, not by WinUtil. If you re-export a preset, leave the WPFInstall section empty so installs flow through the path with idempotency, logging, and exit-code handling we control.

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

Also: `Update-Index.ps1` excludes `.git/`, `.trunk/`, `.vscode/`, `apps/<binaries>`, `logs/`, and `state.json`. CI uses a fresh checkout so the local-only `.trunk/` (trunk.io cache) and `.vscode/` directories must be filtered to keep local and CI line counts equal.
