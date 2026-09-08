# macOS -- agent instructions

Read `../AGENTS.md` first. This file is only what is true of the macOS
implementation; the measurements behind it are in `../docs/measurements.md`, and
`README.md` here holds the how-tos.

## Hazards

**Hard rule 5's emitters.** Shipping: `ddc_send` in `lib/display.sh`, the only
line that can name `input-alt` (m1ddc's spelling of I2C source `0x50`); the
source is chosen from the configured method inside it and it refuses unless the
vendor is `DDC_VENDOR_GSM`. Instrument: `i2c_set_lg_input_alt` in
`intel-ddc-probe.c`, numeric, never installed, not built by default, gated on GSM
(decision 004). `tests/conventions.tests.sh` scans both languages and self-tests
the scan.

**Bluetooth presence comes from `system_profiler SPBluetoothDataType -xml`, not
IOBluetooth.** IOBluetooth is TCC-gated per binary: an unapproved binary's first
call blocks until a human approves a prompt, with the process alive, so
`KeepAlive` never restarts it and the trigger silently never fires.
`system_profiler` raises no prompt (~60 ms, a plist). So Bluetooth is POLLED, and
only when a `bt:` device is configured. A hang under TCC is indistinguishable
from a slow prompt: never conclude anything about a permission-gated API from a
timeout.

**Sleep/wake fires nothing here** (the Mac Studio keeps USB powered through
sleep). Do not add edge-tracking for it; re-measure if the hardware changes.

**The log rotates by TRUNCATING, never by renaming.** launchd opens
`StandardErrorPath` once; the watcher's stderr IS that descriptor, so a rename
would strand every later line in `.log.1`. `event-watch.c` copies then
`ftruncate`s (measured: no NUL hole). The watcher writes to stderr only;
`--log` names the file so it knows what to rotate.

**An abandoned lock is a Windows condition with no macOS equivalent.** `flock` is
released by the kernel when the holder dies; there is deliberately no takeover
code in `event-watch.c`.

**Nothing here runs as root, and the installer refuses to.** Under `sudo`,
`id -un` is root and the boot daemon would run as root on a user-writable config.
`tk_refuse_root` guards the installer, `configure` and `tk_apply_tier`.

**A launchd label is per DOMAIN, so the two tiers coexist unless one removes the
other.** `tk_apply_tier` owns both plists: boot deletes the LaunchAgent file,
login or no writes it back. Nothing else writes either plist.

**`tk_bootstrap` in `lib/manage.sh` is the only function that may load a job into
launchd, and its failure is caught, never thrown.** The bootout runs first, so
between the two calls nothing is watching. The boot tier can fail two ways (no
password, launchd refused) and both fall back to login, say why, and rewrite
`install.autostart`. Enforced by `conventions.tests.sh`.

**The boot tier is a LaunchDaemon with `UserName` set: root installs it, the user
runs it, unelevated.** Display identity, `m1ddc` and a full `pull` all work with
no logged-in session (measured).

## Build and test

Both C programs compile clean under `-Wall -Wextra`. `plutil -lint` a plist
before claiming an install path works.

```sh
cd macos
make            # event-watch and display-probe
make test       # shellcheck + the suite; no hardware needed
make mutate     # reintroduce each bug the suite should catch
```

**The suite cannot move a monitor or reach launchd.** `M1DDC` points at a
recorder, `display-probe` at a fixture, every `launchctl` is `"$TK_LAUNCHCTL"`
(a recorder that can also refuse), and Bluetooth reads `TK_BT_PLIST` when set.
No test may assert this desk's devices: take a present device from the live list
and skip, saying so, when there is none.

**A test that did not run is never a pass.** Use `exit_skipped` (whole file,
exit 2 with a `SKIPPED:` line) or `skip_case`; `run.sh` surfaces both and a skip
never raises the exit code.

**`mutate.sh` edits sources in place.** Ctrl-C, TERM and HUP restore; a SIGKILL
leaves the tree mutated, `run.sh` refuses while a `.mutbak` exists, and
`mutate.sh` restores strays on start. Keep both guards. A mutation is judged only
against a suite that passes unmutated; otherwise it is `UNJUDGED`.

**Shell scoping.** In `lib/`, every `_`-prefixed variable a function assigns is
declared `local`; UPPERCASE names are the deliberate globals. A function that
must edit `WT_*` state cannot return through `$(...)`; use an out-parameter
global as the existing ones do. An assertion inside `cmd | while read` runs in a
subshell and its failure is lost; use a here-string. All three are scanned by
`conventions.tests.sh`.

**Every menu read runs inside `menu_tty_guard`**, which restores the terminal on
INT and TERM. No raw read outside it, no second INT trap under it.

`pause`, never kill: `KeepAlive` restarts a killed watcher in a fifth of a
second. How to run a watcher by hand is in `README.md`.
