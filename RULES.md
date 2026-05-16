# Rules

The non-negotiables for contributing to `win_dell`. Full context in [CLAUDE.md](CLAUDE.md); this file is the punchy "do / don't" summary.

## Code

1. **PowerShell 5.1 only.** Target machines do not have PowerShell 7. No null-coalescing (`??`), null-conditional (`?.`), or `??=` operators. Use `if/else`.
2. **Strict mode is on.** `Get-Content` on a single-line file returns a string, not an array — wrap in `@(...)` before `.Count`. Same for `Select-String` results.
3. **No hardcoded `C:\ProgramData\WinDeploy` paths in stage scripts.** Import `core/Config.psm1` and use `$WD.*`. Pre-Config-load scripts (`install.ps1`, `bootstrap.ps1`, `uninstall.ps1`, `Resilience.psm1` early log, `Monitor.ps1` pre-WPF) are the only allowed exceptions and are whitelisted in `lint.ps1`.
4. **Stage scripts must return exactly one hashtable** as their final pipeline output: `@{ Status = 'Complete'|'RebootRequired'|'Failed'; Message = '...' }`. Anything else flowing to the pipeline (especially `& native.exe ... 2>&1`) gets concatenated into `Object[]` and the orchestrator rejects the stage. Capture native command output into a variable.
5. **Never call `Restart-Computer` from a stage.** Return `RebootRequired` and let the orchestrator do it.
6. **`Write-Host` is banned in stage scripts** (bypasses the log file). Use `Write-LogInfo` / `Write-LogSuccess` / `Write-LogWarning` / `Write-LogError` from `core/Logging.psm1`.
7. **Never use `Add-Content` for log writes** (corrupts under concurrent SYSTEM writers). Use `[System.IO.File]::AppendAllText(path, text, UTF8)`.
8. **Import-Module without `-Force`** for shared modules (Logging, Config) from within other modules. Nested `-Force` imports scope-trap exports — observed breaking `Initialize-Logger` after `Winget.psm1` loaded.

## Winget

9. **Every winget install passes `--source winget`.** The msstore source's TLS cert pinning fails under SYSTEM (exit `-1978335138` = `0x8A15005E` PINNED_CERTIFICATE_MISMATCH). `WINGET_MANIFEST` installs (`--manifest`) bypass source resolution and don't need the flag.
10. **Always go through `Invoke-WingetCli`** from `core/Winget.psm1`. It captures stdout+stderr into a variable (no pipeline pollution), logs every line, and returns a structured `@{ ExitCode; Success; Meaning; Output }` result.
11. **Add new exit codes to `$Script:WINGET_EXIT_MEANINGS`** when they show up in the wild. Source: `src/AppInstallerSharedLib/Public/AppInstallerErrors.h` in microsoft/winget-cli.
12. **`WINGET_MANIFEST` over MSI/EXE** when a vendor URL exists. We want one CLI owning all downloads + SHA256 verification + silent handling + exit codes.

## Stages

13. **Stage list lives only in `core/Config.psm1`** (`$WD.StageOrder` + `$WD.StageLabels`). Never duplicate it.
14. **Adding a new stage** is the seven-step checklist in [memory `project_adding_stages`]: stage script, return contract, StageOrder, StageLabels, STAGE_SCRIPTS, settings.json entry, RebootAllowedStages if applicable.
15. **`WindowsUpdate` runs last** because it takes the longest and reboots multiple times. **`RemoteAccess` runs before `WindowsUpdate`** so the machine stays remotely debuggable during the long update phase, and after `InstallTailscale` so TrustedHosts can be scoped to `100.*` (Tailscale CGNAT).

## Tasks

16. **All scheduled tasks are registered by `Resilience.psm1::Assert-ScheduledTasks`**. Single source of truth.
17. **`-RepetitionInterval` requires `-RepetitionDuration`**, e.g. `-RepetitionDuration (New-TimeSpan -Days 9999)`. Without it the generated XML is missing `EndBoundary` and the task fails to register on Win 10/11.
18. **`-LogonType Interactive` is incompatible with `-GroupId`.** Omit `-LogonType` for group-based principals.
19. **The Watchdog rewrites `watchdog.ps1` every run** even when its scheduled task exists — to keep deployed machines on the current logic across upgrades.

## Troubleshooting

20. **First move when stuck**: `tools\Troubleshoot.ps1 -Action Status` writes a forensic snapshot to `<LogDir>\auto-snapshot-<timestamp>.txt`. The same script auto-fires on every failure / abort / watchdog-detected stall.
21. **Hot-patch a single file** without a full reinstall: `tools\Troubleshoot.ps1 -Action Repair -Stage <name>` (plugins ship for `TimeSync`, `InstallTailscale`, `WindowsUpdate`; add new stages by extending `$Script:StagePlugins`).
22. **Refresh deployed code** = re-run the `install.ps1` one-liner. `bootstrap.ps1` alone does NOT pull from GitHub — it re-uses the extracted repo. `install.ps1` writes a `VERSION` stamp; `bootstrap.ps1` warns when VERSION is >7 days old.

## Git / CI

23. **Pre-commit hook regenerates `INDEX.md` in a loop** until `git diff INDEX.md` is empty (self-reference convergence). Don't disable the hook.
24. **`Update-Index.ps1` excludes `.git/`, `.trunk/`, `.vscode/`, `.claude/`, `apps/<binaries>`, `logs/`, `state.json`.** Local-only directories must be filtered so local and CI line counts agree.
25. **CI auto-commits `manifest.json` + `manifest.sig` after every push to main.** `git pull --rebase` before the next push.
26. **Never `git push --force` to `main`.** Never skip pre-commit hooks (`--no-verify`) or bypass signing.

## Markdown

27. **All `.md` filenames are uppercase** (`README.md`, `CLAUDE.md`, `RULES.md`, `INDEX.md`, `MEMORY.md`, `docs/GPG-SETUP.md`). Lowercase is reserved for files outside the repo (e.g. user-home memory slugs).
