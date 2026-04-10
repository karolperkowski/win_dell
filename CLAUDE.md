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
|---|---|
| `install.ps1` | `irm\|iex` entry point -- downloads repo, verifies manifest, launches bootstrap |
| `bootstrap.ps1` | Sets up scheduled tasks, state, launches monitor + orchestrator |
| `core/Orchestrator.ps1` | Master controller -- runs stages in order, handles reboots |
| `core/Config.psm1` | Shared constants (`$WD.*`) -- single source of truth for all paths and stage order |

---

## PowerShell 5.1 rules -- enforce on every change

| Forbidden | PS 5.1 alternative |
|---|---|
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

## Stage pipeline order

`PowerSettings > Debloat > WinTweaks > InstallDellSupportAssist > InstallDellPowerManager > InstallRustDesk > InstallTailscale > RemoteAccess > WindowsUpdate > Cleanup`

`RemoteAccess` runs after `InstallTailscale` so WinRM TrustedHosts can be scoped to the Tailscale CGNAT (`100.*`), and before `WindowsUpdate` so the machine remains remotely debuggable across the long update phase.

WindowsUpdate runs **last** because it takes the longest and requires multiple reboots.

---

## Logging

Use `Write-LogInfo`, `Write-LogSuccess`, `Write-LogWarning`, `Write-LogError` from `Logging.psm1`.
**Never use `Write-Host` in stage scripts -- it bypasses the log file.**
**Never use `Add-Content` for log writes -- use `[System.IO.File]::AppendAllText` to handle concurrent writers.**
