# macOS side

> **Being brought to parity with Windows.** Phases 1-3 of
> [`../docs/macos-parity.md`](../docs/macos-parity.md) have landed: the switcher
> reads the same config file the Windows side writes, the `pull` / `to` / `list`
> / `discover` / `status` / `restart` / `pause` / `logs` verbs work, and the
> watcher is config-driven across USB and Bluetooth. The menus, the walkthrough
> and the checks are still to come. Read that document before changing anything
> here.

A LaunchAgent runs `trigger-kvm watch`, which reads the config and execs the
watcher; the watcher fires `trigger-kvm pull` when a watched device arrives.

## Requirements

```sh
brew install m1ddc
```

Xcode command line tools for `clang` (you almost certainly already have them).

## Install

```sh
make install     # build, install, write the plist, load the agent
make status      # is the agent loaded?
make logs        # tail ~/Library/Logs/trigger-kvm.log
make uninstall
make test        # the suite -- no hardware, cannot move a monitor
make mutate      # reintroduce each bug the suite should catch
```

Only `~/.local/bin/trigger-kvm`, a single symlink, goes on PATH. The program
directory is never published: putting it on PATH would make every file in it a
command.

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

**Autostart is login-only on macOS, and `status` says so rather than pretending
the tiers match.** The Windows "from boot" tier runs *as the user, unelevated*,
in session 0 — admin is needed once to register it and nothing elevated runs on
the switch path. There is no macOS equivalent: a LaunchDaemon starts before
login but runs as **root**, and the switcher must not run as root to obtain a
tier. There would be nothing for it to do anyway, since both `display-probe` and
`m1ddc` use CoreGraphics, which needs a logged-in session.

`pull` and `to` are one lookup but two verbs, and the split is a safety
property, not style. `computer.this` describes inputs on hardware this Mac is
plugged into and can be sure of; any other name describes inputs on hardware it
**cannot observe**, which go stale the moment someone moves a cable over there.
**The trigger may only ever run `pull`**, so a stale name can spoil a command
you typed and are watching, never an automatic switch.

## Configuration

`~/Library/Application Support/trigger-kvm/config` — the same flat `key = value`
format the Windows side uses, documented in
[`../docs/macos-parity.md`](../docs/macos-parity.md) §2. Everything is read at
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
`idVendor`/`idProduct`. Bluetooth is **polled**, and only when a `bt:` device is
configured — `[IOBluetoothDevice pairedDevices]` from a command-line binary
never returns (measured 2026-08-31, twice, with and without a run loop pumping
and an 8s watchdog), so presence comes from `system_profiler
SPBluetoothDataType -xml`, which answers in about 60ms and is a property list
CoreFoundation parses natively.

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

## Testing

```sh
make test        # shellcheck + the suite
make mutate      # every mutation must be caught
```

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

The agent is post-login by design. `m1ddc` and `display-probe` both link
CoreGraphics and cannot work in session 0; see the root README.
