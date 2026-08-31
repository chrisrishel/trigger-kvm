# macOS side

> **Being brought to parity with Windows.** Phase 1 of
> [`../docs/macos-parity.md`](../docs/macos-parity.md) has landed: the switcher
> now reads the same config file the Windows side writes, and the `pull` / `to`
> / `list` verbs work. `discover`, the config-driven watcher, the menus, the
> walkthrough and the checks are still to come. Read that document before
> changing anything here.

A LaunchAgent runs the watcher, which fires `trigger-kvm pull` when a watched
USB device arrives.

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
trigger-kvm pull --only asus     one monitor only -- use when testing
trigger-kvm pull --dry-run       resolve and print the packets, send nothing
```

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

**`usb-watch.c`** — `IOServiceAddMatchingNotification` on `IOUSBHostDevice`,
filtered by `idVendor`/`idProduct`. Two safety behaviours, both because a
spurious arrival would yank both displays out from under whatever you're doing:

- **debounce** (default 3.0s) — ignore arrivals within N seconds of the last
  fire. Stops two watched devices arriving together from firing twice, and stops
  a flapping device from thrashing the displays.
- **settle** (default 0.75s) — after an arrival, wait, then confirm the device is
  *still* present before acting. Appear-then-vanish was a glitch, not a switch.

Devices already present at startup do not fire; the first callback per watch only
drains and arms the notification.

```
usb-watch --exec PATH [--arg pull] --device VVVV:PPPP [--device ...] \
          [--debounce SECONDS] [--settle SECONDS] [--verbose]
```

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

- **Respawn after `kill -9`: 0.01s.** launchd replaced the process essentially
  instantly and incremented its run count.
- **Full `make uninstall` → `make install` round trip**: uninstall unloaded the
  agent and removed the plist and the binaries; install rebuilt, reloaded, and
  the watcher logged a fresh start.

## Notes

`IOUSBHostDevice` is the correct matching class on Apple Silicon — the older
`IOUSBDevice` name is not reliable here.

The agent is post-login by design. `m1ddc` and `display-probe` both link
CoreGraphics and cannot work in session 0; see the root README.
