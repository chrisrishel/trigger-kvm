# Windows release checks

Run from a clean candidate checkout, in **Windows PowerShell 5.1**. Record the
commit, OS/driver versions, account type, commands, outcomes and skips in
`docs/measurements.md`. Product version remains 0.2.0 during remediation;
the next coordinated target is 0.3.0 (`../CONTRIBUTING.md`).

## Automated checks (no physical switching)

```powershell
cd windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\mutate.ps1 publication
```

Run mutations alone: they temporarily edit source and restore it. The suite
uses process-specific fixture paths. It exercises actual Windows Script Host,
child-process quoting/exit codes, process ownership, DLL loading and hidden
console buffers. Task Scheduler transitions in the behavioral suite are mocks;
the native cleanup tests use bounded, harmless children. The command-boundary
test restricts CIM enumeration to its recorded fixture PIDs and checks 13 real
PowerShell 5.1 invocation forms plus the generated WSH/watcher launch chain.
It confirms script identity and arguments before asserting cleanup decisions.
Transport tests enumerate real displays and use `-WhatIf`; none prove that a
physical panel changed input.

## Candidate status and next coordinated session

The 2026-10-30 cleanup follow-up is covered by native process fixtures; it has
not been installed over the live boot-tier copy. The earlier upgrade, installed
status/Cancel and timeout-restoration checks were observed on 2026-10-29.
The ASUS dxva2 away-and-back check was visually confirmed that day; this
follow-up performed no display writes. Fresh profiles, account elevation,
autostart transitions and final NVAPI physical checks remain open.

For the next agreed installation session, follow the backup/pause/upgrade steps
below using the pushed candidate. After backing up the configuration, add the
synthetic unknown key `release.fixture = keep` to the saved config. Run
`trigger-kvm configure` through the installed shim, Save without changing
monitor inputs, verify the key survives, and restore the original config.
Run the trigger check and interrupt it with Ctrl+C; compare prior and resulting
task enablement and watcher lock state. Keep the owner's original tier/state.
Use approved disposable profiles for the separate account, reboot and uninstall
matrix. Coordinate physical switching as its own one-panel-at-a-time session.

These are outstanding release gates alongside the privacy review in `TODO.md`;
automated cleanup validation does not clear them.

## Coordinate before changing an installation

The desktop's existing task, watcher, PATH and configuration are user state.
Schedule the following with the person at the desk. Keep backups private;
configuration, logs and task XML can contain personal identifiers.

1. Record `trigger-kvm status`, the saved config, the installed version stamp,
   and the task definition. Back up the config and installed program directory
   before an upgrade. Record task enablement and whether the watcher holds its
   lock. Determine whether the session is local; RDP cannot validate dxva2.
2. Use `trigger-kvm pause`, elevated if the boot-tier task requires it. Verify
   the lock is released. Never substitute `Stop-ScheduledTask` or kill a watcher.
3. Upgrade with the source installer, keeping the existing tier. Verify that
   saved config keys survive, files land in the intended user's profile, the
   stamp names the source commit/revision, and exactly one watcher holds the
   lock. Use `trigger-kvm restart` only if it was running before the check;
   return a deliberately paused installation to its paused state.
4. Run `configure` and `status` **through the installed shim**. Check that
   Cancel leaves the saved configuration intact and a Save preserves unknown
   keys. Confirm trigger-check cleanup for an enabled/running,
   enabled/stopped and disabled/stopped task. Include timeout and Ctrl+C.
   An enabled task's self-heal can start it later; distinguish that from a
   start performed by the check.

## Fresh profiles and autostart tiers

Use disposable profiles approved by the owner, never repurpose their normal
account. A fresh directory under an existing profile is not a fresh-profile
installation test. Account creation, logoff and reboot require coordination.

- Administrator-capable account: first install unelevated; choose boot and
  approve UAC. Confirm S4U, RunLevel Limited, correct user principal and files.
- Standard account with a separate administrator credential: repeat boot
  installation; verify files and PATH belong to the standard user, not the
  administrator. The elevated child must not change its administrator's PATH.
- Decline UAC on a fresh install: verify the stated login fallback and the
  saved `install.autostart = login`, only after task registration succeeds.
- Login tier: confirm Interactive principal, automatic logon start and only one
  task. Transition between boot and login in both directions.
- No autostart: confirm no task triggers, watcher starts now, and it does not
  return after a new login/restart until explicitly started.
- Use checkout and profile paths containing spaces, an apostrophe and non-ASCII
  characters. Test the generated VBS launcher, installed CMD shim and repeated
  config updates. Isolated native fixtures cover these encodings; real profile
  installation is a separate check.
- Upgrade with configuration preserved, then uninstall from the installed
  shim after moving the source checkout aside. Confirm task/program/PATH
  removal, config/log retention, and no unrelated script or user's process
  stopped. Restore the source location afterwards.

## Physical switching (one monitor at a time)

The person at the desk confirms the terminal is on the monitor that stays on
Windows. Do not proceed on a remote session for dxva2, or if there is no second
working display. Disable monitor auto-input selection as described in the root
README. Pause the installed watcher before manual checks.

1. Read `trigger-kvm list` and `status`. Resolve by EDID at runtime. Identify
   the **standard-DDC** panel to test and the saved name of the other computer.
   Do not change the LG's method or aim its service channel at another panel.
2. Copy the saved config to a private temporary file. Change only the selected
   standard panel's `transport` to `dxva2`. Keep all input values unchanged.
   Run a dry run first:

   ```powershell
   # Set these to the reviewed label, other computer name and temporary config.
   $panel = Read-Host 'Configured standard-DDC panel label'
   $other = Read-Host 'Saved name of the other computer'
   $probeConfig = Read-Host 'Absolute path of the temporary config'
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\trigger-kvm.ps1 to $other -Only $panel -Config $probeConfig -WhatIf
   ```

3. With the terminal confirmed on the other display, send that one panel away.
   Ask what the person sees; a successful command is not confirmation.

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\trigger-kvm.ps1 to $other -Only $panel -Config $probeConfig
   ```

4. Bring the same panel back and obtain a second visual confirmation.

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\trigger-kvm.ps1 pull -Only $panel -Config $probeConfig
   ```

5. With dxva2 selected in the walkthrough, confirm the boot row is visible and
   disabled, naming the affected panel. Cancel unless saving that change was
   agreed. Remove the temporary file and restore the original watcher state.
6. Revalidate NVAPI one panel at a time with the original saved config. Before
   testing the LG, move the terminal to the other monitor. Use only documented
   or explicitly user-supplied values. Require visual confirmation in both
   directions; never read VCP values to verify a write.

After a graphics-driver update or first reboot on the recorded driver, run the
read-only `nvapi-probe.ps1`, privately compare the identity fields with the
earlier measurement, and record equal/changed labels without publishing unique
identifiers. A same-GPU port-move check requires the owner to move the cable,
with the terminal on the other display. **Do not test S3 standby.**
