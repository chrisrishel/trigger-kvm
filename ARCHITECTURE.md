# Architecture

## The problem

Two machines share two monitors. The conventional answer is a KVM in the video
path, which failed here: at 5120×2160@165Hz the LG needs DSC over a 25.92 Gbps
HBR3 link, and routing that through a switch plus ~16ft of copper produced
uncorrectable bit errors, visible speckling, and link dropouts.

## The approach: pull-to-self

Remove the switch from the video path entirely. Give **each machine its own direct
connection to each monitor**, and move only the USB peripherals. Whichever machine
receives the peripherals tells both monitors, over DDC, to select its own inputs.

```
             ┌── USB-C ──────────────┐
Mac Studio ──┤                       ├── LG 45GX950A   (USB-C | DisplayPort)
             └── USB-C→DP ───────┐   │
                                 ├───┼── ASUS PG42UQ   (DisplayPort | HDMI 1)
Windows PC ──── DisplayPort ─────┘   │
           └─── HDMI 1 ──────────────┘

USB switch ──> peripherals ──> arriving machine pulls both displays to itself
```

Each machine only ever pulls *toward* itself. Neither pushes the other away, so
there is no coordination protocol, no shared state, and no race: only one machine
holds the peripherals at a time, so only one fires.

## The property that makes it work

**A host's link to a monitor stays enumerated while that monitor displays a
different input.** macOS continues to report the display as online at full
resolution even when the panel is showing the other machine. Windows behaves the
same way — both monitors stay in `EnumDisplayMonitors` with full desktop rects
while showing the Mac, and both accept DDC writes in that state. Confirmed
independently on both platforms, so the property is a monitor behaviour rather than
an OS quirk either side happens to have.

Two consequences, and both are load-bearing:

1. **There is always a DDC path home.** The machine issuing a switch command is by
   definition not the one being displayed. If the link dropped when deselected,
   pull-to-self would be impossible and the design would collapse to push-only.
2. **Window layout survives switching.** The OS never sees a disconnect, so it
   never rearranges windows. This is the main day-to-day win over the KVM, which
   dropped the link and caused macOS to pile windows onto the remaining display.

The second point has a corollary worth knowing: if only *one* monitor is switched,
windows stay on a display you can no longer see. In normal operation both move
together, so this only surfaces during asymmetric testing.

## Components

```
displays.toml          the contract — shared by both platforms
├── macos/
│   ├── usb-watch.c          detects arrival  →  execs the switcher
│   └── switch-displays.sh   drives m1ddc     →  sends the DDC writes
└── windows/
    ├── usb-watch.ps1        detects arrival  →  execs the switcher
    ├── switch-displays.ps1  dxva2 + lg-input-switch → sends the DDC writes
    └── install.ps1          Scheduled Task at logon (generates launcher.vbs)
```

On Windows the watcher is a *grandchild* of the scheduled task — the task runs a
generated `wscript.exe` shim, which is what keeps any console from being allocated,
and the shim runs the watcher. Stopping the task therefore does not stop the
watcher, so `usb-watch.ps1` enforces single-instance itself with a named mutex.
`windows/README.md` covers the reasoning.

Every platform implementation is the same two roles: **a detector** and **a
switcher**. The detector answers "do I own the peripherals now?"; the switcher
answers "make the monitors show me." They are separate processes so the switcher
stays usable by hand and testable in isolation.

## Why `displays.toml` exists

There is no shared code between platforms. macOS reaches DDC through
`IOAVService`; Windows reaches it through NVAPI and the Monitor Configuration API.
No runtime, no language, no library in common.

What *is* common is the **map**: which monitor, addressed how, with what value for
which machine. That is the part that silently rots when duplicated — a value fixed
on one machine and not the other produces a half-switching setup that looks like a
hardware fault. `displays.toml` is the single place those values are stated, and
each implementation is expected to match it.

It is a contract, not a config file that gets parsed at runtime. The macOS switcher
duplicates the values as literals deliberately: it runs from a LaunchAgent on every
device arrival and should not depend on a TOML parser being present. Changing
`displays.toml` means changing the implementations to match, in the same commit.

## Why two different DDC methods

The two monitors do not speak the same dialect:

| Monitor | Method | Why |
|---|---|---|
| ASUS PG42UQ | Standard DDC/CI, VCP `0x60` | Works normally |
| LG 45GX950A | I2C source `0x50`, VCP `0xF4` | Standard input control is **stubbed** on this panel |

This split is why neither platform has a single code path. macOS reaches both
through `m1ddc` (`set input` vs `set input-alt`); Windows reaches the ASUS through
`dxva2.dll` and the LG by shelling out to `lg-input-switch`, because the Windows
DDC/CI stack hardcodes I2C source `0x51` and cannot express `0x50` at all.

The LG accepts `VCP 0x60` writes, returns success, and discards them; reads always
return `0x0F` regardless of what is displayed. Recent LG monitors moved input
control to a manufacturer sidechannel ("DDC2AB"). This is not a workaround for a
bug — it is the only functioning interface on that hardware.

Address `0x50` is a service channel. Only the values in `displays.toml` are known
safe; sweeping VCP codes there has bricked LG monitors.

## Verification is visual, by necessity

DDC reads are unreliable on both monitors and produced false negatives during
development — the ASUS returns `0` for everything including `max luminance`, and
the LG returns `-7` while its link is inactive or renegotiating. Both monitors
switched correctly while reads said they had not.

Writes are fire-and-forget. **A switch is only confirmed by looking at the screen.**
No automated verification is possible with this hardware, which shapes both the
tooling (no verify-then-retry loops) and the workflow (a human confirms every
behavioural change).

## Robustness: debounce and settle

A spurious USB arrival yanks both displays out from under whatever the user is
doing. This desk has a documented history of USB instability, so the detector
treats arrivals as untrusted:

- **debounce** — ignore arrivals within N seconds of the last fire; stops two
  watched devices arriving together from double-firing, and stops a flapping device
  from thrashing the displays.
- **settle** — after an arrival, wait, then confirm the device is *still* present.
  Appear-then-vanish was a glitch, not a switch.

Devices already present at startup never fire.

## Scope: post-login only

Both platforms are post-login by design, and this is a deliberate limit rather than
an oversight.

`m1ddc` links CoreGraphics and enumerates displays via `CGGetOnlineDisplayList`,
which requires a window server connection. A LaunchDaemon in session 0 has none and
would enumerate zero displays. Windows hits the same wall: session 0 has no
desktop, so `GetPhysicalMonitorsFromHMONITOR` has no `HMONITOR` and NVAPI display
enumeration is expected to fail for the same reason. The Windows side is therefore
a Scheduled Task at logon in the interactive session, not a Windows Service.

Pre-login on macOS has a known clean path if it ever becomes worth building:
enumerate `DCPAVServiceProxy` entries where `Location = External` directly from
IORegistry, match on the display's identity, then `IOAVServiceCreateWithService` +
`IOAVServiceWriteI2C` — no CoreGraphics anywhere. The Windows equivalent is
unexplored.

**Do not key that on the EDID product ID without checking it first.** The LG reports
a *different product ID on every input* — three consecutive values have been
measured on this one panel, one per path (see `displays.toml`). Each host sees a
stable value for the input it is plugged into, so it is usable as a local key, but
it is meaningless as a shared constant and must never be copied between hosts. The
ASUS does not behave this way, which makes it easy to assume the field is stable
when it is not.
