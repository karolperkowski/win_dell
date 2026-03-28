# WinDeploy - Unattended Post-Install Automation Framework

> **Repo:** https://github.com/karolperkowski/win_dell

A fully unattended Windows 10/11 post-install automation framework driven by
PowerShell. Manual trigger once; everything after that is automatic.

---

## Quickstart — one-liner

Open PowerShell **as Administrator** on a fresh Windows install and run:

```powershell
irm "https://raw.githubusercontent.com/karolperkowski/win_dell/main/install.ps1" | iex
```

That's it. The script will:
1. Re-launch itself elevated if not already admin
2. Download the full repo from GitHub (no git required)
3. Run `bootstrap.ps1`, which registers the resume-after-reboot task
4. Hand off to the orchestrator — walk away

> **Tip:** To pin to a specific release instead of `main`:
> ```powershell
> irm "https://raw.githubusercontent.com/karolperkowski/win_dell/v1.0.0/install.ps1" | iex
> ```

---

## Architecture Decision: Why Scheduled Task?

| Mechanism | Pro | Con | Verdict |
|---|---|---|---|
| `SetupComplete.cmd` | Runs once at end of sysprep | Hard to restart after reboot; no loop support | ❌ |
| `unattend FirstLogonCommands` | Runs at first logon | One-shot; limited error handling | ❌ |
| `RunOnce` | Simple per-boot execution | Deleted on first run; no retry logic | ❌ |
| **Scheduled Task** | Runs at every boot AND logon; SYSTEM context; survives reboots; easy to remove when done | Slightly more setup | ✅ **Chosen** |

The Scheduled Task approach is used here because:
- It fires at both **startup** (before logon) and **logon** (after), covering all reboot scenarios
- Runs as **SYSTEM** — no credential prompts
- The orchestrator removes it when deployment is complete
- It is simple to inspect, suspend, or re-trigger manually

---

## Repo Structure

```
WinDeploy/
├── bootstrap.ps1              # Manually triggered ONCE after OS install
├── README.md
│
├── config/
│   └── settings.json          # All configuration - apps, stage options, flags
│
├── core/
│   ├── Orchestrator.ps1       # Main controller - runs all stages in order
│   ├── State.psm1             # State tracking module (JSON persistence)
│   ├── Logging.psm1           # Structured logging module
│   ├── WindowsUpdate.ps1      # Stage: install all Windows Updates
│   ├── PowerSettings.ps1      # Stage: configure power/display settings
│   ├── Debloat.ps1            # Stage: remove bloatware
│   ├── AppInstall.ps1         # Stage: silent app installs (Dell SA, PM, etc.)
│   └── Cleanup.ps1            # Stage: remove task, disable auto-logon, report
│
├── apps/
│   ├── DellSupportAssistInstaller.exe     # Drop installer binaries here
│   └── DellPowerManagerInstaller.exe
│
├── data/
│   └── bloatware.json         # Configurable removal lists
│
└── logs/                      # Created at runtime in C:\ProgramData\WinDeploy\Logs\
```

---

## Usage

### Option A — One-liner (recommended, no git required)

```powershell
irm "https://raw.githubusercontent.com/karolperkowski/win_dell/main/install.ps1" | iex
```

`install.ps1` handles elevation, downloads the repo ZIP from GitHub,
verifies integrity, and calls `bootstrap.ps1` automatically.

### Option B — Manual (USB / network share / air-gapped)

### Step 1 — Clone / copy the repo

```powershell
# From USB, network share, or after cloning from GitHub:
git clone https://github.com/YOU/WinDeploy.git C:\Deploy
```

### Step 2 — Drop installers (optional)

Copy Dell installer `.exe` files into `apps/`. If you leave them out, the
scripts fall back to the `DownloadUrl` in `settings.json`.

### Step 3 — Run bootstrap (single manual trigger)

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\bootstrap.ps1
```

That's it. The framework takes over from here. Walk away.

### What happens next (automatically)

```
bootstrap.ps1
  │
  ├─ Creates C:\ProgramData\WinDeploy\state.json
  ├─ Copies repo to C:\ProgramData\WinDeploy\repo\
  ├─ Registers WinDeploy-Resume scheduled task (boot + logon triggers)
  ├─ Configures auto-logon (Administrator, blank password)
  └─ Launches Orchestrator.ps1 immediately
       │
       ├─ Stage 1: WindowsUpdate     ← installs updates, reboots as needed
       ├─ [REBOOT] ← scheduled task resumes orchestrator
       ├─ Stage 1: WindowsUpdate     ← resumes, installs more updates if any
       ├─ [REBOOT if needed]
       ├─ Stage 2: PowerSettings     ← display never off, never sleep
       ├─ Stage 3: Debloat           ← removes bloatware per lists
       ├─ Stage 4: InstallDellSupportAssist
       ├─ Stage 5: InstallDellPowerManager
       └─ Stage 6: Cleanup           ← removes task, disables auto-logon, reboots
```

---

## State File

`C:\ProgramData\WinDeploy\state.json` — never delete this during a deployment.

```json
{
  "SchemaVersion": 1,
  "BootstrappedAt": "2024-01-15T09:00:00",
  "CurrentStage": "Debloat",
  "CompletedStages": ["WindowsUpdate", "PowerSettings"],
  "RebootCount": 2,
  "DeployComplete": false
}
```

To restart a deployment from scratch (testing):
```powershell
Import-Module C:\ProgramData\WinDeploy\repo\core\State.psm1
Reset-DeployState -Force
```

---

## Customising Dell App Installers

Edit `config/settings.json` → `Apps` section:

```json
"InstallDellSupportAssist": {
  "LocalPath": "DellSupportAssistInstaller.exe",
  "DownloadUrl": "https://dl.dell.com/...",
  "InstallerType": "EXE",
  "SilentArgs": "/s /v\"/qn /norestart\"",
  "SuccessExitCodes": [0, 3010],
  "Detection": {
    "Method": "Registry",
    "DisplayName": "Dell SupportAssist",
    "MinVersion": "3.0.0"
  }
}
```

**Dell packaging notes:**
- SupportAssist 3.x ships as a bootstrapper EXE wrapping an MSI.
  The `/s /v"/qn"` flag combination passes `/qn` through to the inner MSI.
- Power Manager 3.x is typically a pure NSIS EXE; use `/S` (capital S).
- Both products have changed silent-install flags between major versions.
  **Always verify flags against the specific build you are deploying.**
- Exit code `1603` from msiexec = generic MSI failure (check temp log).
- Exit code `1618` = another installer is already running (serialise installs).

---

## Common Failure Points and Prevention

| Failure | Symptom | Prevention |
|---|---|---|
| PSGallery not reachable | `Install-Module` hangs or fails | Pre-cache PSWindowsUpdate in the repo; set `TrustedRepositories` in config |
| Dell installer silent flags wrong for your version | Exit code `1` or `5` with no effect | Test flags manually before automating: `DellSA.exe /s /v"/qn"` |
| Auto-logon password wrong | Machine sits at lock screen after reboot | Set correct password in `Set-AutoLogon` call in bootstrap.ps1 |
| `Get-AppxPackage` removal fails due to WinSxS | Removal throws `Deployment failed` | The `ContinueOnError: true` on Debloat absorbs this; it's non-fatal |
| State file corrupted mid-write | Orchestrator crashes on next boot | Atomic write (tmp → rename) + lock file guards against this |
| WU scan times out on first run | No updates installed, stage loops | Increase `$MAX_UPDATE_CYCLES` or pre-seed WSUS/WU settings |
| Scheduled task fires before network ready | Installer download fails | Add `-RunOnlyIfNetworkAvailable` + retry logic in AppInstall.ps1 |
| Credential in registry not cleaned up | Security risk post-deployment | Cleanup stage always runs `Disable-AutoLogon`; verify in logs |

---

## Logs

All logs under `C:\ProgramData\WinDeploy\Logs\`:

- `bootstrap.log` — bootstrap run
- `session.log` — everything, all stages, all runs
- `WindowsUpdate_20240115_090010.log` — per stage, per invocation
- `completion_report.txt` — final summary after all stages complete
