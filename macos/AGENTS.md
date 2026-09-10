# macOS -- agent instructions

Read `../AGENTS.md` first. This file is only what is true of the macOS
implementation; the measurements behind it are in `../docs/measurements.md`, and
`README.md` here holds the how-tos and the file map.

## Hazards

**Hard rule 5's emitters.** Shipping: `ddc_send` in `lib/display.sh`, the only
line that can name `input-alt` (m1ddc's spelling of I2C source `0x50`); the
source is chosen from the configured method inside it, it refuses unless the
vendor is `DDC_VENDOR_GSM`, and a dry run passes the gate before it prints.
Instrument: `i2c_set_lg_input_alt` in `intel-ddc-probe.c`, numeric, never
installed, not built by default, gated on GSM (decision 004).
`tests/conventions.tests.sh` scans both languages and self-tests the scan.

**Bluetooth presence comes from `system_profiler SPBluetoothDataType -xml`, not
IOBluetooth.** IOBluetooth is TCC-gated per binary: an unapproved binary's first
call blocks until a human approves a prompt, with the process alive, so
`KeepAlive` never restarts it and the trigger silently never fires.
`system_profiler` raises no prompt (~60 ms, a plist). So Bluetooth is POLLED, and
only when a `bt:` device is configured. A hang under TCC is indistinguishable
from a slow prompt: never conclude anything about a permission-gated API from a
timeout.

**USB removal is not observed.** IOKit delivers first-match notifications only,
so the watcher decides from the arriving services plus a fresh snapshot
(`usb_arrived`), never from a remembered present/absent flag. Under
`TK_USB_LIST` it polls the fixture instead and diffs snapshots.

**Sleep/wake fires nothing here** (the Mac Studio keeps USB powered through
sleep). Do not add edge-tracking for it; re-measure if the hardware changes.

**The log rotates by TRUNCATING, never by renaming.** launchd opens
`StandardErrorPath` once; the watcher's stderr IS that descriptor, so a rename
would strand every later line in `.log.1`. `event-watch.c` copies then
`ftruncate`s (measured: no NUL hole). The watcher writes to stderr only;
`--log` names the file so it knows what to rotate.

**An abandoned lock is a Windows condition with no macOS equivalent.** `flock` is
released by the kernel when the holder dies; there is deliberately no takeover
code in `event-watch.c`. A lock that cannot be opened or taken for any reason
other than "held" is a refusal, never a warning.

**Nothing here runs as root, and the installer refuses to.** Under `sudo`,
`id -un` is root and the boot daemon would run as root on a user-writable config.
`tk_refuse_root` guards the installer, `configure` and `tk_apply_tier`.

**A launchd label is per DOMAIN, so the tiers coexist unless one removes the
others.** `tk_apply_tier` owns all three plists: boot deletes both agent plists,
login and "no" write theirs and delete the other's. "No" lives at
`$TK_SESSION_PLIST`, inside the program directory, never in
`~/Library/LaunchAgents`. Nothing else writes any of them.

**`tk_bootstrap` in `lib/manage.sh` is the only function that may load a job into
launchd, and its failure is caught, never thrown.** The bootout runs first, so
between the two calls nothing is watching. The boot tier can fail two ways (no
password, launchd refused) and both fall back to login and say why. The config
records the downgrade only once the login plist is written, never where the boot
half failed (`specs/configure.md` 8). Enforced by `conventions.tests.sh`.

**The boot tier is a LaunchDaemon with `UserName` set: root installs it, the user
runs it, unelevated.** Display identity, `m1ddc` and a full `pull` all work with
no logged-in session (measured).

**Whether a watcher is running is asked of the lock** (`tk_watcher_running`,
through `event-watch --lock-status`), never by counting processes. `status` and
`pause` both use it; `pause` fails when the lock is still held.

## Build and test

Both C programs compile clean under `-Wall -Wextra`. `plutil -lint` a plist
before claiming an install path works.

```sh
cd macos
make            # event-watch and display-probe
make test       # shellcheck + the suite; no hardware needed
make mutate     # reintroduce each bug the suite should catch; `make mutate` alone
                # takes about forty minutes, `bash tests/mutate.sh <name|file>` a subset
```

**The suite cannot move a monitor or reach launchd.** `M1DDC` points at a
recorder, `display-probe` at a fixture, every `launchctl` is `"$TK_LAUNCHCTL"`
(a recorder that can also refuse), USB reads `TK_USB_LIST` and Bluetooth
`TK_BT_PLIST` when set. No test may assert this desk's devices: stage them in
the fixtures.

**A test that did not run is never a pass.** Use `exit_skipped` (whole file,
exit 2 with a `SKIPPED:` line) or `skip_case`; `run.sh` surfaces both, a bare
exit 2 is a FAIL, and a skip never raises the exit code.

**`mutate.sh` edits sources in place.** Ctrl-C, TERM and HUP restore; a SIGKILL
leaves the tree mutated, `run.sh` refuses while a `.mutbak` exists, and
`mutate.sh` restores strays on start. Keep both guards. A mutation is judged only
against a suite that passes unmutated; otherwise it is `UNJUDGED`. Do not edit
`macos/` while it runs.

**Shell scoping.** In `lib/`, every `_`-prefixed variable a function assigns is
declared `local`; UPPERCASE names are the deliberate globals. A function that
must edit `WT_*` state cannot return through `$(...)`; use an out-parameter
global as the existing ones do. An assertion inside `cmd | while read` runs in a
subshell and its failure is lost; use a here-string. A function defined twice
shadows its first definition. All four are scanned by `conventions.tests.sh`.

**Walkthrough state is one record per panel** (`WT_F`, `WT_A` in
`lib/answers.sh`), unpacked with `wt_found` / `wt_rec` into `F_*` / `R_*`. Edit
a record with `wt_answer_set`; never splice a field by hand.

**Every menu read runs inside `menu_tty_guard`**, which restores the terminal on
INT and TERM. No raw read outside it, no second INT trap under it.

`pause`, never kill: `KeepAlive` restarts a killed watcher in a fifth of a
second. How to run a watcher by hand is in `README.md`.
