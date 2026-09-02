# macOS -- agent instructions

Read `../AGENTS.md` first; it holds the hard safety rules and everything both
platforms share. This file is only what is true of the macOS implementation. The
dated measurements behind it are in `../docs/measurements.md`.

## Hazards learned here

**Hard rule 5's gate is `ddc_send` in `lib/display.sh`.** It is the only line that
can name `input-alt` (what m1ddc calls I2C source `0x50`), the source is chosen
from the configured method inside it, and it refuses unless the vendor is
`DDC_VENDOR_GSM`. `tests/conventions.tests.sh` asserts that `input-alt` appears in
exactly one non-comment line and that no function takes a source byte. Keep it so.
The OTHER emitter is `i2c_set_lg_input_alt` in `intel-ddc-probe.c`: numeric, so
the `input-alt` scan cannot see it and a second scan covers `*.c`. Instrument
only, never installed, gated on GSM itself. Decision 004.

**Bluetooth presence comes from `system_profiler`, and the reason is a PERMISSION
GATE, not a broken API.** IOBluetooth needs TCC Bluetooth permission, granted PER
BINARY. An unapproved binary's first call BLOCKS until a human approves a prompt,
which can arrive minutes later; once approved it works fine, from a terminal and
from a LaunchAgent alike. What makes it unusable is the FIRST run on a fresh
install: the watcher's first sweep would block with the process still ALIVE, so
`KeepAlive` would not restart it and the trigger would silently never fire. A
background watcher must not wait on a human. `system_profiler SPBluetoothDataType
-xml` never raises that prompt (Apple-signed, own entitlement), costs about 60ms,
and is a plist, so CoreFoundation parses it with no JSON dependency. Nothing
subscribes on that route, so Bluetooth is POLLED -- and only when a `bt:` device
is configured, so a USB-only setup pays nothing.

**A hang under TCC is indistinguishable from a slow prompt. Do not conclude
anything about a permission-gated API from a timeout.** The entry above was wrong
TWICE before it was right ("the API never returns"; "a LaunchAgent can never get
permission") -- both artefacts of the measuring window. If something TCC-gated
appears to hang, look for a pending prompt first, and prefer the route that needs
no permission at all.

**Sleep/wake does NOT fire a spurious switch here.** The Mac Studio keeps its USB
ports powered through sleep, so the devices are never torn down and no new
`kIOFirstMatchNotification` occurs. Do not add edge-tracking to solve a problem
that does not exist. Scope: one cycle, on a desktop with powered USB; a laptop or
a hub that drops power could still re-enumerate. Re-test rather than assume if
the hardware changes.

**The log rotates by TRUNCATING, never by renaming.** launchd opens
`StandardErrorPath` ONCE, when it starts the job, and the watcher's stderr IS that
descriptor. Renaming would leave it pointing at the renamed inode, so every line
after the first rotation would land in `trigger-kvm.log.1` while the live log
stayed empty. `event-watch.c` copies then `ftruncate`s, which keeps the inode;
measured to leave no NUL hole. Rotation is at startup, after the lock, as on
Windows.

**The watcher writes to STDERR ONLY, and `--log` names the file stderr is already
pointed at.** It exists so the watcher knows what to rotate, not as a second place
to write -- writing to both put every line in the log twice on the first real
install. It also keeps an arrival and the switch it caused in order: the spawned
switcher inherits stderr, so one stream carries both.

**An abandoned lock is a WINDOWS condition with no macOS equivalent. Do not port
the takeover code.** Windows uses a named mutex that outlives its owner; macOS
uses `flock`, which the kernel releases when the holder dies however it dies. A
force-killed watcher leaves nothing behind, and there is deliberately no takeover
code in `event-watch.c`.

**Nothing here runs as root, and the installer refuses to.** Under `sudo`,
`id -un` is root, so the boot daemon would be written to run as root on a
user-writable config, and every file created would be root-owned.
`tk_refuse_root` guards the installer, `configure` and `tk_apply_tier`.

**A launchd label is per DOMAIN, so the two tiers can coexist unless one removes
the other.** `tk_apply_tier` owns both plists: choosing boot deletes the
LaunchAgent file (booting it out covers this session only -- it would start
again at login beside the daemon and respawn on the lock every ten seconds),
and choosing login or no writes it back. Nothing else writes either plist.

**`tk_bootstrap` in `lib/manage.sh` is the ONLY function that may load a job into
launchd, and its failure is CAUGHT, never thrown.** Its bootout runs first, so
between the two calls nothing is watching; under `set -euo pipefail` an unchecked
`bootstrap` aborted inside that window, leaving `status` reporting "at boot" off
a plist on disk with nothing running. The other shape was `|| true` then an
unconditional "restarted". Elevation is not a parameter -- it follows from the
domain; the BOOTOUT stays best-effort, since it fails whenever nothing is loaded.
The boot tier can fail to land two ways, no password or launchd refusing, and
both take the ONE answer: fall back to login, say why, rewrite
`install.autostart` -- which is also what removes the daemon plist.
`conventions.tests.sh` holds the seam as the only door.

**The boot tier is a LaunchDaemon in `/Library/LaunchDaemons` with `UserName`
set, so it runs AS THE USER, UNELEVATED.** Root installs it into the system
domain; root does not run it -- the same property the Windows S4U tier has, and
the tier is not worth having without it. This file previously said macOS was
post-login only, on two claims measured wrong: a LaunchDaemon with `UserName`
does not run as root, and reading the displays does NOT need a logged-in session
-- IOKit display identity, `m1ddc display list` and a full `trigger-kvm pull`
all work as uid 501 with no session. See `specs/CHANGELOG.md` revision 4.

## Build and test

Both C programs must compile clean under `-Wall -Wextra`. Verify the plist with
`plutil -lint` before claiming an install path works -- a malformed plist fails
silently at load.

```sh
cd macos && bash tests/run.sh          # or: make test
```

The suite **cannot move a monitor**: `M1DDC` points at a recorder and
`display-probe` at a fixture, so even a test driving the program through a path
nobody anticipated writes a line to a file, not a packet to a panel -- stronger
than stubbing one function. The harness runs `set -euo pipefail` and
`shellcheck`, because the scripts do.

**A test that did not run is never reported as one that passed.** `run.sh` shows
a file's output only on FAIL, so a skip written to stderr was swallowed and its
exit 0 counted as a pass -- without python3 the whole pty-driven half went
untested under "all 11 test files passed". Use `exit_skipped` (whole file, exit
2) or `skip_case` (one case, tallied by `finish`); both print a `SKIPPED:` line,
which `run.sh` surfaces whatever the verdict. A skip does not raise the exit
code: it is a fact about the machine, not a failure.

`tests/mutate.sh` reintroduces every bug the suite is supposed to catch; all of
them must be caught. **A `mutate.sh` killed outright (SIGKILL) leaves the source
MUTATED**: it cannot run its trap, and the next `make` builds the mutant -- which
once cost an hour chasing a lock bug that did not exist. Ctrl-C, TERM and HUP
restore and stop. `tests/run.sh` refuses to run while a `.mutbak` is present,
and `mutate.sh` restores strays on startup. Do not remove either guard. A
mutation is judged only against a suite file that passes unmutated; a red suite
makes its mutations `UNJUDGED`, not "caught".

**The suite must never reach the real launchd.** Every `launchctl` in the
program is `"$TK_LAUNCHCTL"`, which the harness points at a recorder;
`tests/conventions.tests.sh` fails on a bare one. Before the seam existed, each
scripted `configure` that reached Save booted out the developer's live watcher.
**And no test may assert this desk's devices**: `watcher.tests.sh` takes its
present device from the live `--list` and skips, saying so, when there is none;
the Bluetooth semantics run against a plist fixture the watcher reads in place
of `system_profiler` (`TK_BT_PLIST`, set only by the suite).

To exercise the watcher without installing:

```sh
trigger-kvm pause                         # stand the installed watcher down
./event-watch --exec /bin/echo --arg TEST --device usb:046d:c547 --verbose
trigger-kvm restart                       # restore it afterwards
```

`046d:c547` is the keyboard receiver, always present, so this is the direct check
that already-present devices do not fire: it should log `armed (N already present,
not firing)` and **not** fire. `pause` rather than `kill`: `KeepAlive` restarts a
killed watcher in about a fifth of a second, so killing it is not standing it
down. `pause` unloads the agent; `restart` bootstraps it again.

**Shell variables are GLOBAL unless declared `local`, and in `lib/` every
`_`-prefixed name a function assigns must be.** A callee's loop index otherwise
overwrites its caller's: `select_many`'s `_i` clobbered `wt_check_round`'s, and the
monitor check crashed on an unbound array subscript the first time a batch was
narrowed -- a path no unit test had reached. UPPERCASE names are the deliberate
globals; `_lowercase` is scratch. A variable only READ is fine, and is how a
helper reads its caller's state under bash's dynamic scoping. No single mutation
reproduces this, so `tests/conventions.tests.sh` scans for it directly.

**Every menu runs inside `menu_tty_guard`, which restores the terminal on INT
and TERM.** `menu_read_key` restores it on the normal path only; Ctrl-C arrives
while it is blocked in `dd` and left the caller's shell with no echo. Do not
add a raw read outside the guard, and do not set another INT trap under it.

**A function that must edit `WT_*` state cannot return its result through
`$(...)`**: a command substitution is a subshell and the edits are lost. Use an
out-parameter global (`WT_INPUT_VALUE`, `WT_REMAINING`) as the existing ones do.
