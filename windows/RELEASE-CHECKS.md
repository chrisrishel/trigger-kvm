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

The native bootstrap-dependency fixture starts fresh PowerShell 5.1 children
with an isolated hostile Utility module, DLL/compiler bait and process-only
environment changes. Its control proves both substitute commands can resolve;
the protected bootstrap rejects that path on success, restriction failure and
malformed payload/assembly failures. Existing tests verify actual child token
rights, owner/session, quoted paths and exit codes. UAC eligibility keeps the
independent `whoami` membership check and adds an independent policy read;
controlled policy fixtures cover permitted, denied and unavailable settings.

## Candidate status

Windows source now implements specification revision 16 in both common menu
primitives. Native hidden-console fixtures cover 30 synthetic cases, including
small visible windows, physical folds/Unicode, a wider scrollback buffer,
resize, page/end navigation, disabled/separator rows, Done and numbered
fallback retaining current choices, including Escape arriving at the resize
boundary. All 16 viewport, 3 existing menu and 2
existing folded/tail-redraw mutations were caught. This changes only menu
interaction: the installed `6f65aff` below remains unchanged at revision 15,
and its boot/profile/physical evidence is reused for unchanged behavior.
The final native Windows PowerShell 5.1 suite passed all 23 files without skips,
including parsing/conventions and revision-16 conformance. Product version
remains 0.2.0; privacy and coordinated publication gates remain open.

The 2026-10-31 review follow-up, implementation candidate **`7e65036`**, confirms
pre-restriction module loading under native PowerShell 5.1 and moves compilation
to task registration. The protected task embeds the assembly and performs only in-memory Framework operations
before restricting the token; failure reports directly to stderr. Normal and
error-path adversarial mutations are caught. The stale installation-guide
claim is corrected, and existing installed/reboot/physical evidence below is
retained for unchanged behavior.

Native Windows PowerShell 5.1: all 22 test files passed without skips, including
parsing/conventions; all 14 boot, 3 standard-user and 3 elevation mutations were
caught. Run commands and evidence limits are in `../docs/measurements.md`.
CI for `7e65036` (validation record retained privately)
passed on both platforms: Windows 21 files with one hardware-dependent file
and two driver cases explicitly skipped; macOS 13 files passed. Local native
Windows validation ran all 22 files without skips.

On 2026-10-31, four bounded S4U/Limited session-0 tasks passed: the original
bootstrap executed the hostile-module control with enabled administrator
membership; the secured bootstrap launched an identity-only child with the
intended owner/session, medium integrity, no administrator/power-user membership
and only change-notify privilege. It returned the child's exit code 7.
Restriction and assembly failures returned 1 without a child, substitute module
or privileged user-log write. All four tasks were removed. Current config,
installed stamp, task XML/enabled/running state, watcher lock and PATH matched
before/after snapshots. No account rights, installation, reboot or monitors
were changed. This closes the affected-context validation gap.

The owner's installed candidate is now **`6f65aff`**, product 0.2.0 /
specification 15. The authorized supported-installer upgrade on 2026-10-31
regenerated the secured bootstrap, preserved current configuration bytes and
PATH, and left the boot task enabled with exactly one owned watcher running.
Installed source hashes/stamp and the actual ordinary session-0 token passed;
independent checks confirmed the lock and a bootstrap with no command lookup.
Private program/config/task/PATH backups are retained. No reboot or physical
write was repeated; existing manual evidence is reused for unchanged behavior.

Earlier installed/reboot evidence is tied to **`6a5afcf`**. The supported
installer restored its intended boot/enabled/running state on 2026-10-30.
Source hashes/stamp matched the clean checkout, configuration bytes and owner
PATH were unchanged, and exactly one intended watcher held its lock. Its
actual session-0 token had medium integrity, no
administrator/power-user membership and only change-notify privilege. The
temporary Switch user policy is restored to its original value.
The restored owner's final real reboot also passed: one restricted watcher
started about 39 seconds after boot and 22 seconds before the first interactive
login, with source identity/config/PATH unchanged. The read-only post-reboot
NVAPI identity comparison matched the baseline on driver 616.64.

Completed installation evidence on Windows 11 build 22631 / PowerShell 5.1:

- The disposable administrator-capable profile passed fresh setup, approved
  boot/declined login fallback, boot/login/manual transitions, real reboot and
  logon checks, installed Save/Cancel and source-unavailable uninstall on the
  earlier recorded candidates. `462204a` confirmed user-owned login/manual
  tasks and no additional UAC for login-to-manual.
- The standard profile passed corrected `6a5afcf` boot registration with separate
  administrator credentials and its own password. Credential Cancel preserved
  program/config/PATH and absent task/watcher state. Successful setup preserved
  config/PATH, matched source hashes, and produced one restricted boot watcher.
  After a real restart it started 39 seconds after boot and 174 seconds before
  the first interactive logon. The actual token was verified in both cases.
- Through the standard profile's installed shim, boot-to-login produced a
  user-owned task; Save preserved an unknown key and Cancel preserved config
  bytes, which were restored afterward. Real sign-out/sign-in started one new
  login watcher; the manual tier had no watcher or triggers after another login.
  Fresh product-state UAC decline produced a working login fallback. Both
  source-unavailable uninstalls removed program/task/watcher/PATH entry and
  retained exact config/log bytes. Original PATH entries/order survived; one
  trailing semicolon was normalized away.
- Actual profile and checkout paths contain spaces, an apostrophe and Unicode.
  The elevated standard-profile program directory is owned by Administrators;
  its config is owned by the intended user, who successfully configured and
  uninstalled it. Archive identity uses the retained manifest/source hashes;
  the archive stamp correctly says it is not a Git checkout.
- Installed real Ctrl+C preserved enabled/running on `2835cb0` before scheduler
  self-heal; enabled/stopped and disabled/stopped passed on `4c0f13b` without
  helper recovery or self-heal. The stopped cases required three presses before
  CMD's termination prompt. Error paths remain fixture coverage.

The full native PowerShell 5.1 suite passed all 21 files without skips again
after this session. The clean `6a5afcf` suite also passed 21; all 12 affected
boot mutations were caught after the prior full 53-mutation publication run.
CI `41163702720` at documentation commit `1f00e7e` passed macOS 13 files and
Windows 20, with the NVIDIA resolution file and two driver cases explicitly
skipped. The coordinated session-0 bootstrap fixture and its missing-integrity
mutation passed; both bounded tasks were removed. These are separate from
installed-product and physical observations.

Final restricted-session checks also passed on 2026-10-30. Bounded native tasks
used the installed `6a5afcf` bootstrap and switcher; all four `-WhatIf` cases and
four one-panel writes returned success with the intended ordinary session-0
token. The owner explicitly confirmed ASUS away/back with LG kept on Windows,
then LG away/back after moving the terminal to ASUS, with ASUS kept on Windows.
Both panels returned to Windows. No fixture tasks remain; the original watcher,
config/PATH and intended enabled/running state were independently verified.
The private console's final serializer failed after restoration; its individual
command/token receipts survived, and the owner supplied a separate explicit
chat confirmation. The collector was reproduced/fixed under native 5.1 and its
original conversion mutation caught, without repeating the writes.

These physical writes ran after local sign-in in session 0. They establish the
restricted transport path, not a detector-triggered or pre-login physical write.
Earlier ASUS dxva2 (2026-10-29) and local-console NVAPI (2026-10-30) observations
remain separate evidence; switcher/config source is identical to that candidate.
No S3 standby test was performed.

The administrator-PATH comparison passed using Windows' read-only offline
registry API on a clean private hive copy, whose hash remained unchanged.
Earlier live-load attempts of copies failed; none changed the original hive
or left temporary registry mounts. Read-only account-right comparison confirmed
only the standard user's expected added batch-logon grant; successful product
installation retains it after uninstall by design. With the owner's explicit
approval, cleanup restored that grant to baseline and removed both disposable
accounts/profiles after privately backing up both. All 19,223 regular files
matched their backup hashes; 140 links were preserved as reparse metadata
without following their targets. Independent checks confirmed both profiles
and accounts absent, the original installation/state intact and the temporary
Switch user policy restored. Private backups and validation evidence are retained.

Still required: both native suites at the coordinated release commit and the
separate privacy review. The owner explicitly kept publication blocked on
2026-10-30. Deferred driver/port checks keep their documented triggers.

See `../docs/measurements.md` for dated receipts, candidate history and limits.
Never test S3 standby.

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

For future candidates, repeat the checks affected by the changes and retain
the dated evidence for unchanged code. Batch profile work into a coordinated
session, then restore the owner's configuration, tier, enabled/running state
and any temporary user-switching policy. Verify one ordinary-rights watcher
in session 0. Coordinate reboot and physical checks separately. Back up and
remove disposable profiles only after the owner approves that destructive
cleanup; stop if a profile is loaded, referenced by a task or not fully backed up.

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
