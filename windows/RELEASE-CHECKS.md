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
PowerShell 5.1 invocation forms plus the WSH and restricted boot launch chains.
It confirms script identity and arguments before asserting cleanup decisions.
Fixture reports become visible only after their complete writes; a gated native
self-test checks that publication boundary.
Transport tests enumerate real displays and use `-WhatIf`; none prove that a
physical panel changed input.

## Candidate status and next coordinated session

Clean reviewed candidate `2835cb0` was installed on 2026-10-30. Installed script
hashes, build identity (0.2.0/spec 15), configuration preservation, intended
S4U/Limited principal, owner PATH and one enabled/running watcher were verified.
Installed Save preserved a synthetic unknown key; Cancel preserved config bytes.
Original config bytes and the owner's boot/enabled/running state were restored.
The earlier timeout-restoration checks were observed on 2026-10-29.
The ASUS dxva2 away-and-back check was visually confirmed that day. On
2026-10-30, installed `2835cb0` passed interactive Ctrl+C from enabled/running:
one watcher returned before the next scheduled self-heal, without helper
recovery. NVAPI away-and-back writes on each panel were visually confirmed,
one panel at a time with the other kept on Windows. Post-reboot read-only
NVAPI IDs matched the baseline on driver 616.64. The fresh standard-user
installation and separate administrator-credential cases remain open.

The first fresh administrator-capable profile installed the `2835cb0` archive
successfully in the login tier, with profile and source paths containing spaces,
an apostrophe and Unicode. Intended files/PATH, source hashes, Interactive/Limited
principal and one watcher were verified. From boot was incorrectly disabled:
the eligibility query omitted deny-only administrator membership. Corrected
`4c0f13b` passed the installed repeat: upgrade preserved config bytes; From boot
was selectable unelevated; declining UAC retained a working login tier; approving
UAC installed S4U/Limited for the intended user with one watcher. Save/Cancel
and unknown-key preservation passed in this profile too. The first profile run
did not reach a UAC prompt; that fallback had existing config. A subsequent
fresh product-state install, after preserving the retained data, passed actual
UAC decline and login fallback. Standard-user product registration remains open.
A real reboot on `4c0f13b` started
one intended S4U/Limited watcher in session 0 before any test-profile sign-in;
the owner confirmed signing into only the original account. The read-only
collector checked boot/process timestamps and task ownership. This verifies
startup, not physical switching from session 0.
The installed boot-to-login transition also passed: after an actual sign-out
and sign-in, one new intended watcher ran in the new interactive session under
the correct Interactive/Limited task.
Login-to-no-autostart started one watcher immediately; an actual sign-out/
sign-in left it stopped with an enabled, trigger-free task. The transition
requested UAC because the elevated boot-to-login replacement left a protected
task definition. Read-only task-security inspection confirmed this; it does
not mean the watcher runs elevated.

The fresh standard-user profile's read-only probe accepted a separate
administrator credential, while `462204a` incorrectly reported boot ineligible.
The current correction reads Windows UAC policy and permits that credential
path unless explicitly disabled. Installed `ed1a0c0` made boot selectable and
accepted separate administrator credentials, but registration of the standard
user's S4U task failed with access denied. Config/program files were written
in the intended profile and matched the candidate; no task or watcher existed,
and the installer returned 1. Its intermediate success messages were incorrect.
Task-operation error handling is corrected. Bounded tasks
also denied own-standard-user S4U registration without triggers; the
administrator control ran and cleanup left zero fixture tasks. Follow-up process
inspection confirmed TokenElevation 1/type 1 and enabled administrator membership
despite registered RunLevel Limited. Password-authenticated COM S4U registration
then succeeded; execution required a separate batch-logon grant. Temporary
rights and tasks were restored/removed. The source now implements cross-user
credential entry, batch-logon permission and a protected bootstrap that restricts
effective privileges and integrity. Validate these through the installed shim,
including credential Cancel/failure, the actual session-0 watcher token, cleanup,
one watcher and required device access. Fixture and bounded task results do not
close those installation gates.
Candidate `473274d` and its clean checkout passed all 21 native test files
without skips; all 53 publication mutations were caught. CI `41153314261`
passed both platforms. Hosted Windows passed 20 files, with one NVIDIA-dependent
file and two driver cases skipped; macOS passed 13. The bounded session-0
bootstrap check and installed repeat must be recorded separately.
The probe's initial decline and later approval are not installation-fallback
results: neither run installed the product or registered a task.
The current source corrects this by elevating only old-task removal and
registering the replacement in the normal parent. It also corrects uninstall's
CMD return path: the installed `4c0f13b` check removed task/program/PATH and
retained config/log bytes, but CMD returned 1 after its shim was deleted.
Both corrections have regression/mutation coverage. Installed `462204a` passed
the upgrade with config bytes/PATH preserved, then boot-to-login and
login-to-no-autostart. Native task security confirmed user ownership of both
replacement definitions; the owner confirmed no UAC on the final change.
Each user tier had one intended watcher; the final manual task had no triggers.
The subsequent source-unavailable uninstall returned 0, removed task/program
and the installed PATH entry, stopped the watcher, and retained config/log
bytes and all original PATH entries.
The earlier `462204a` clean native suite passed all 19
files without skips and CI passed on both platforms, with hosted hardware
skips recorded in `docs/measurements.md`.

Installed `4c0f13b` passed real Ctrl+C from enabled/stopped and disabled/stopped
in elevated disposable-profile consoles, preserving task enablement, stopped
watcher state and config bytes without helper recovery. The no-autostart task
had no self-heal trigger. The owner needed three Ctrl+C presses in each case
before CMD asked to terminate the batch job; single-press responsiveness was
not established. Keep the owner's original tier/state.
Use approved disposable profiles for the separate account, reboot and uninstall
matrix. The owner watcher is deliberately paused during that session; restore
its boot/enabled/running state when finished. Repeat physical checks if changes
to the candidate affect the tested paths; these observations do not establish
fresh-boot/session-0 writes.

These are outstanding release gates alongside the privacy review in `TODO.md`;
automated cleanup validation does not clear them.
The owner explicitly kept publication blocked for a separate privacy review
on 2026-10-30.

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
The task name is machine-wide: pause the original owner's watcher and preserve
its task XML before another profile installs. Test one profile at a time, then
return to the owner and restore the original configuration, tier and state.
Stage only candidate source in the shared temporary source folder, never the
owner's config, logs or private backup. Have the owner enter credentials directly
in Windows; do not put them in transcripts or chat. Verify the actual profile
path, since an account's display name alone does not prove a Unicode path.

- Administrator-capable account: first install unelevated; choose boot and
  approve UAC. Confirm S4U, RunLevel Limited, correct user principal and files.
  Verify the actual watcher process token is unelevated; task settings alone
  are insufficient, following the bounded control's confirmed elevated token.
- Standard account with a separate administrator credential: repeat boot
  installation; verify files and PATH belong to the standard user, not the
  administrator. The elevated child must not change its administrator's PATH.
  Enter the intended standard user's password in the separate boot-registration
  dialog, never in chat or a transcript. Check Cancel preserves the old task and
  program files; a failed authentication must not claim success. Record the
  batch-logon right before/after. Registration failure must undo only a new grant;
  successful setup retains it for the task and does not revoke it on uninstall.
  Verify no password appears in task XML, command lines, config or logs.
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

Batch the remaining standard-profile work into one coordinated session: upgrade
the failed partial installation, inspect ownership/PATH/build/token, run installed
Save/Cancel, exercise the user tiers and their required sign-ins, then uninstall
with source unavailable. Retain already-passed administrator-profile evidence;
repeat only boot checks affected by the token bootstrap. Restore the original
owner on the final candidate, verify one ordinary-rights watcher in session 0,
then coordinate the final reboot and one-panel-at-a-time NVAPI checks. Restore
the temporary Switch user policy afterward; remove disposable profiles only
after the owner approves that destructive cleanup.

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
