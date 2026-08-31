# macOS side

At parity with the Windows side. The shared behaviour is specified in
[`../specs/`](../specs/) and the hard safety rules in
[`../AGENTS.md`](../AGENTS.md) — read both before changing anything here.
Almost everything in them was arrived at by getting it wrong first, on real
hardware.

**Change the spec first**, then this implementation, then append an entry to
[`../windows/HANDOFF.md`](../windows/HANDOFF.md) saying what Windows owes.
[`HANDOFF.md`](HANDOFF.md) here is the other direction — read it before starting
work, because it is what *this* side owes.

A LaunchAgent runs `trigger-kvm watch`, which reads the config and execs the
watcher; the watcher fires `trigger-kvm pull` when a watched device arrives.

## Requirements

```sh
brew install m1ddc
```

Xcode command line tools for `clang` (you almost certainly already have them).

## Install

```sh
cd macos && ./install.sh      # build, install, load the agent, walk you through it
```

That is what installing *is*, and it is why there is no `install` verb: installing
is what produces the command. Upgrading and repairing both mean "fetch the source
and run its installer", which works because the install is self-contained — the
installer copies itself alongside the program, so managing and removing keep
working after the source tree is gone.

Nothing needs `sudo`, at install or at run time.

```sh
./install.sh uninstall        # remove the program; keep the config and the log
make test                     # the suite -- no hardware, cannot move a monitor
make mutate                   # reintroduce each bug the suite should catch
```

Only `~/.local/bin/trigger-kvm`, a single symlink, goes on PATH. The program
directory is never published: putting it on PATH would make every file in it a
command.

## The walkthrough

`trigger-kvm configure` — **the menu is the flow.** There is no separate
first-run questionnaire: an empty install is the same menu with `not set` in it
and the cursor already on the first thing that needs an answer; a configured one
is the same menu with the answers in it.

```
--- configuration ---

 > 1) Computers                    not set
   2) Monitors                     not set
   3) Triggers                     not set
   4) Autostart?                   not set
   5) Add to PATH?                 not set

   7) Test the monitor inputs      untested
   8) Test the triggers            untested

  10) Save configuration and run
  11) Cancel (discard changes)
```

- **Nothing is preset.** Autostart and PATH have obvious answers, but the
  suggestion belongs on the highlighted row *inside* their menu, not in the value
  column of a menu nobody has opened.
- **Nothing is written until Save**, so an interrupted run leaves a working setup
  untouched. Save refuses while a required section is `not set`, naming what is
  missing — writing half a setup produces a config the switcher then declines to
  act on, which is a worse way to find out.
- Where the cursor lands is the recommendation: unanswered sections in order,
  then the checks in order, then Save. **A failed check sends the cursor to the
  setting that failed**, not onward.
- Computers are asked **before** the monitors, so a computer is described once
  rather than once per screen, and every panel then offers the same names. A
  rename is carried into every panel's map; the monitors are never re-asked.
- **Standard** DDC/CI is the default for every panel, whatever the make. Where
  the panel's manufacturer has a documented alternative, that choice is *offered*
  up front — never probed, never chosen for you — and the check offers it again,
  in either direction, if the chosen method turns out not to answer.

## The checks

What is under test is the claim that **input V of panel P is computer C**. A
panel that answers every command perfectly while its inputs are mapped to the
wrong computers fails this and is not broken — hence "test the monitor
**inputs**".

Rounds are **batched across panels, never across computers**. Monitors sit side
by side, so several are confirmed in one glance; a *sequence* over half a minute
has to be held in memory and reported afterwards, and memory is the weak link.
One question per round, and the four-way diagnosis only appears for the panels
someone says went wrong.

**One panel always stays on this computer**, so the question arrives on a screen
that can be read. When every panel claims the target, that is two rounds. What
stays is measured against *every* managed panel, not just the round's.

With **one monitor** there is nothing to hold back. Being stranded is
unavoidable; being stranded without having been told how to get back is not, and
the telling happens while there is still a screen to read it on — naming the
input in the monitor's own words, because the OSD has never heard of `mac`.

Blind value-walking is the last resort: standard DDC only, MCCS values one at a
time, offered with its cost stated, and **refused outright when it would take the
last display**.

The trigger check comes **after** the inputs, and that ordering is the point:
once the values are confirmed, the flip back can pull the monitors for real, so
it stops being "an event was observed" and becomes the whole thing working. Until
then it reports the arrival and moves nothing, and says so.

## Manual use

```sh
trigger-kvm pull                 point every configured monitor at THIS computer
trigger-kvm to pc                point them at another, by name -- MANUAL ONLY
trigger-kvm list                 what is attached, with EDID ids and names
trigger-kvm discover             what is attached, in the form the config wants
trigger-kvm status               is it running, what that covers, version, config
trigger-kvm restart              make a hand-edited config take effect now
trigger-kvm logs                 tail the log
trigger-kvm pause                stand the watcher down to test by hand
trigger-kvm pull --only asus     one monitor only -- use when testing
trigger-kvm pull --dry-run       resolve and print the packets, send nothing
```

There is no `install` verb, deliberately: installing is what produced the
command. There is no `apply` step either — everything is read at the point it is
used, so display edits take effect on the next switch and trigger edits when the
watcher next starts, which is what `restart` does.

**Both autostart tiers are available.** `From boot` is a LaunchDaemon in
`/Library/LaunchDaemons` with `UserName` set, so it runs **as you, unelevated** —
your password installs it into the system domain, and nothing runs as an
administrator afterwards. That is the same property the Windows S4U tier has,
and the tier would not be worth having without it. `From login` is a LaunchAgent
and needs no password at all.

The two are mutually exclusive: installing one removes the other, because two
live watchers would both fire on the same arrival and the debounce is
per-process.

This was documented as impossible for a while, on two claims that were both
measured wrong — a LaunchDaemon with `UserName` does not run as root, and
reading the displays does not need a logged-in session. Measured from a
LaunchDaemon with no session: IOKit identity works with no CoreGraphics,
`m1ddc display list` works, and a full `pull` works as uid 501.

`pull` and `to` are one lookup but two verbs, and the split is a safety
property, not style. `computer.this` describes inputs on hardware this Mac is
plugged into and can be sure of; any other name describes inputs on hardware it
**cannot observe**, which go stale the moment someone moves a cable over there.
**The trigger may only ever run `pull`**, so a stale name can spoil a command
you typed and are watching, never an automatic switch.

## Configuration

`~/Library/Application Support/trigger-kvm/config` — the same flat `key = value`
format the Windows side uses, specified in
[`../specs/config-format.md`](../specs/config-format.md). Everything is read at
the point it is used, so there is no apply step.

A config is **machine-local**. `computer.this` differs per machine, and the LG
45GX950A reports a **different EDID product id per input** — `0x9E9D` on the
Windows host's DisplayPort cable, `0x9E9F` on this Mac's USB-C. Read the id with
`trigger-kvm list`; never copy one between hosts, because a copied id matches
nothing.

## Components

**`trigger-kvm`** — the one command. Resolves each panel by the EDID vendor and
product on **every** invocation, never by an index and never from a cache.

**Display ordering is not stable, and must never be assumed to be.** A display
dropping is not the only thing that reorders it: on Windows the two indices were
observed swapping outright — `DISPLAY1` going from the ASUS to the LG — across a
reboot and hibernate cycle with both monitors attached the whole time. Index `1`
silently becoming the *other* monitor would send LG service-channel writes to
the ASUS.

Sends each write twice — DDC is lossy and the writes are idempotent. **Never
reads a value back to decide anything**: reads lie on both of these panels.

**`display-probe.c`** — every attached display as
`vendor|product|mfg|connector|serial|uuid|name`. CoreGraphics supplies identity
and the handle `m1ddc` takes in one call, and its vendor/model numbers are
exactly the EDID manufacturer and product code; IOKit supplies the panel's own
name from EDID descriptor tag `0xFC`, which CoreGraphics has no API for. The two
are joined on vendor+product+serial.

**`event-watch.c`** — one process, both transports, and the **one owner of "is
that device here?"**. `--list` exists so `discover` and the walkthrough can ask
this program rather than keeping a second copy of the enumeration: a second
implementation would be free to disagree with the one that actually fires.

USB is `IOServiceAddMatchingNotification` on `IOUSBHostDevice`, filtered by
`idVendor`/`idProduct`. Bluetooth is **polled** via `system_profiler
SPBluetoothDataType -xml`, and only when a `bt:` device is configured.

**Not IOBluetooth, and the reason is a permission gate rather than a broken
API.** IOBluetooth needs TCC Bluetooth permission, granted *per binary*. An
unapproved binary's first call blocks until a human approves a prompt, and that
prompt can arrive minutes later; once approved the API works fine from a
terminal and from a LaunchAgent alike (measured both ways — 10 paired devices
with connected state, no run loop needed, exits cleanly).

The problem is the **first run on a fresh install**: the watcher's first
Bluetooth sweep would block until someone happened to notice a prompt, with the
process still *alive*, so `KeepAlive` would not restart it and the trigger would
silently never fire until it was answered.

`system_profiler` never raises that prompt — it is Apple-signed and carries its
own entitlement, which is why it answered on the very first attempt here, before
any prompt had been seen. It costs about 60ms, and `-xml` is a property list, so
CoreFoundation parses it natively.

Bluetooth fires on **connected**; the candidate list offers every **paired**
device with its state shown but not filtered on. Two different questions: a
trigger fires on arrival, so the device that is disconnected right now is
exactly the one that will produce one.

Two safety behaviours, both because a spurious arrival would yank both displays
out from under whatever you're doing:

- **debounce** (default 3.0s) — ignore arrivals within N seconds of the last
  fire. Stops two watched devices arriving together from firing twice, and stops
  a flapping device from thrashing the displays.
- **settle** (default 0.75s) — after an arrival, wait, then confirm the device is
  *still* present before acting. Appear-then-vanish was a glitch, not a switch.

Devices already present at startup do not fire; the first callback per watch only
drains and arms the notification.

```
event-watch --exec PATH [--arg pull] --device usb:VVVV:PPPP|bt:AAAAAAAAAAAA ... \
            [--debounce S] [--settle S] [--log PATH] [--max-log-bytes N] [--verbose]
event-watch --list           what could be a trigger, and exit
event-watch --test-trigger   report ONE arrival and exit, running nothing
```

**Single instance** is a `flock` on
`~/Library/Application Support/trigger-kvm/watcher.lock`. Note what that means
here: the kernel releases a `flock` when the holding process dies, however it
dies, so the **abandoned-lock condition the Windows side has to catch and take
over does not exist on macOS** — a force-killed watcher leaves no lock behind,
and there is deliberately no takeover code to go looking for.

**Log rotation** happens at startup and only at startup, after the lock — so a
redundant start never rotates a live watcher's log, and doing it once per start
rather than per write means the switcher, appending to the same file, can never
race it. It rotates by **copy-then-truncate, never rename**: launchd opens
`StandardErrorPath` once when it starts the job, and the watcher's stderr *is*
that descriptor, so a rename would leave every later line landing in
`trigger-kvm.log.1` while the live log stayed empty. Measured 2026-08-31 that
truncating a file launchd holds open leaves no NUL hole — its writes land at
offset 0 — which is what makes copy-truncate correct rather than merely
convenient.

The watcher writes to **stderr only**; `--log` names the file stderr is already
pointed at, so it knows what to rotate. Writing to both put every line in the
log twice, which the first real install showed immediately.

## The service channel

I2C source `0x50` is LG's service/factory channel, and sweeping it has bricked LG
monitors. It is reachable from exactly one function, `ddc_send` in
`lib/display.sh`, which refuses any target whose EDID vendor is not GSM
(`0x1E6D`). The channel is chosen there from the configured method rather than
handed in as a source byte, so no caller can aim it at another vendor's panel.

Setting `method = lg-alt` on a non-LG panel makes the write **refuse**. It does
not make the write happen. There is a test for that, and a test that the string
`input-alt` appears in exactly one place in the sources.

## The menus

Every list question in the walkthrough is one of two menus, and in both, **enter
does what the highlighted row says**. That single rule is the whole design: with
"space toggles, enter accepts" the first thing people did was accept an empty
list, because enter is what you press. So a multi-select has no accept key — it
has a `Done` row you move to.

Both fall back to a typed number when the host cannot read individual keys. That
is not a nicety: it is what makes the whole flow testable end to end, and `q` is
the fallback's `esc`.

Nothing in a menu is ever truncated. A long detail wraps at the `", "` between
items onto continuation lines aligned under the column; an unbreakable single
item overruns rather than being cut. The review screen exists to let someone
confirm what is about to be written, and an ellipsis there hides exactly the
thing they came to check.

**The key reader is driven through a real pty in the tests**, not only stubbed.
That is not thoroughness for its own sake — it caught a bug that made the
interactive menu unusable on the first arrow key, while every stubbed test
passed. `read -rsn1` left the terminal in raw mode, so saving and restoring
around the escape-sequence read wrote that raw state back permanently, `VMIN`
stuck at 0, and the next read returned nothing. The reader now reads its own
byte and manages the terminal itself.

## Testing

```sh
make test        # shellcheck + the suite
make mutate      # every mutation must be caught
```

The walkthrough and the checks are driven end to end **through the typed
fallback** — a complete script of answers piped in. That is what the fallback is
for: it exercises the real menus, the real state and the real config writer with
nothing stubbed but the hardware. Running out of answers stops the run and says
so, which turns a flow change into a failed test rather than a hung one.

That stopping is signalled by a non-zero **return**, not by exiting. Almost
every prompt is read inside `$(...)`, and `exit` there kills only the subshell —
the caller then sees an empty answer, re-asks, and spins. Measured: one mutation
run sat on a single `configure` for 28 minutes before the harness grew a
watchdog and the prompt grew a return status.

Two rules are checked **structurally** rather than behaviourally, because no
single mutation reproduces their failure:

- `input-alt` — what m1ddc calls I2C source `0x50` — must appear in exactly one
  non-comment line, inside the function that also holds the vendor gate.
- Every `_`-prefixed variable a function assigns must be declared `local` in it.
  Shell variables are global otherwise, and a callee's loop index silently
  overwrote its caller's: `select_many`'s `_i` clobbered the monitor check's, and
  the check crashed on an unbound array subscript the first time a batch was
  narrowed. With the caller's locals in place a callee's missing ones are
  harmless and vice versa, so it is the *convention* that holds — and the
  convention is what gets scanned for.

The suite cannot move a monitor. `M1DDC` points at a recorder and `display-probe`
at a fixture, so even a test that drives the whole program end to end through an
unanticipated path writes a line to a file instead of a packet to a panel. The
assertion for a refusal is that **nothing was sent**, not that a check ran —
because on Windows the check was present, did not fire, and an unresolved value
went out as `0x00`, an input no monitor has.

Every assertion is mutation-checked: `tests/mutate.sh` reintroduces each bug the
suite is supposed to catch and fails if any survives.

## Watched devices

Currently in the `Makefile` (`DEVICES`), and moving into the config as the
walkthrough lands. Kept in sync with `../displays.toml`:

| Device | ID | Note |
|---|---|---|
| Logitech Webcam C930e | `046d:0843` | Preferred anchor — a UVC camera rarely re-enumerates spuriously |
| Focusrite Clarett+ 2Pre | `1235:820a` | Weaker anchor — audio interfaces re-enumerate on driver reloads and power events |

The keyboard and mouse are wired directly to the Windows PC's motherboard and
never pass through the switch, so they can't be the trigger.

To re-check the ids:

```sh
ioreg -p IOUSB -l | grep -E 'idVendor|idProduct'
```

## Persistence, measured

`RunAtLoad` starts the watcher at login; `KeepAlive` restarts it if it dies. Both
verified 2026-08-30 rather than assumed:

- **Respawn after `kill -9`: 0.21s** (re-measured 2026-08-31 against the current
  agent; an earlier measurement said 0.01s). Well inside the one-minute bound
  the Windows self-heal trigger provides, and with no code of our own to do it.
- **Full `make uninstall` → `make install` round trip**: uninstall unloaded the
  agent and removed the plist and the binaries; install rebuilt, reloaded, and
  the watcher logged a fresh start.

## Notes

`IOUSBHostDevice` is the correct matching class on Apple Silicon — the older
`IOUSBDevice` name is not reliable here.

Both `m1ddc` and `display-probe` link CoreGraphics, but that does **not** stop
them working without a user session — measured from a LaunchDaemon, both work
fine. Identity does not even need CoreGraphics: `display-probe`'s EDID walk is
pure IOKit.
