# macOS side

A LaunchAgent runs `usb-watch`, which fires `switch-displays.sh mac` when a watched
USB device is plugged in.

## Requirements

```sh
brew install m1ddc
```

Xcode command line tools for `clang` (you almost certainly already have them).

## Install

```sh
make install     # build, install to ~/.local/bin, write the plist, load the agent
make status      # is the agent loaded?
make logs        # tail ~/Library/Logs/displayswitch.log
make uninstall
```

## Manual use

```sh
./switch-displays.sh mac       # pull both monitors here
./switch-displays.sh windows   # push both to the PC
```

## Components

**`switch-displays.sh`** — sends the DDC writes via `m1ddc`. Resolves display UUIDs
at runtime by name rather than hardcoding them: m1ddc's index numbers shift when a
display drops, and index `1` silently becoming the *other* monitor would send LG
service-channel writes to the ASUS. Sends each write twice — DDC is lossy and the
writes are idempotent.

**`usb-watch.c`** — `IOServiceAddMatchingNotification` on `IOUSBHostDevice`, filtered
by `idVendor`/`idProduct`. Two safety behaviours, both because a spurious arrival
would yank both displays out from under whatever you're doing:

- **debounce** (default 3.0s) — ignore arrivals within N seconds of the last fire.
  Stops two watched devices arriving together from firing twice, and stops a
  flapping device from thrashing the displays.
- **settle** (default 0.75s) — after an arrival, wait, then confirm the device is
  *still* present before acting. Appear-then-vanish was a glitch, not a switch.

Devices already present at startup do not fire; the first callback per watch only
drains and arms the notification.

```
usb-watch --exec PATH [--arg mac] --device VVVV:PPPP [--device ...] \
          [--debounce SECONDS] [--settle SECONDS] [--verbose]
```

## Watched devices

Set in the `Makefile` (`DEVICES`), kept in sync with `../displays.toml`:

| Device | ID | Note |
|---|---|---|
| Logitech Webcam C930e | `046d:0843` | Preferred anchor — a UVC camera rarely re-enumerates spuriously |
| Focusrite Clarett+ 2Pre | `1235:820a` | Weaker anchor — audio interfaces re-enumerate on driver reloads and power events |

The keyboard and mouse are wired directly to the Windows PC's motherboard and never
pass through the switch, so they can't be the trigger.

Both IDs were confirmed from the Windows side on 2026-08-30 with the devices
actually behind the USB switch, so they no longer need re-checking:

```
USB\VID_046D&PID_0843\5A5A5A5A     Logitech Webcam C930e
USB\VID_1235&PID_820A\00001234     Focusrite Clarett+ 2Pre
```

To re-check anyway:

```sh
ioreg -p IOUSB -l | grep -E 'idVendor|idProduct'
```

## Notes

`IOUSBHostDevice` is the correct matching class on Apple Silicon — the older
`IOUSBDevice` name is not reliable here. Verified: both devices matched at arm time
on this machine.

The agent is post-login by design. `m1ddc` links CoreGraphics and cannot work in
session 0; see the root README.
