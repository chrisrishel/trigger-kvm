# display-switch

Make two monitors follow a USB switch between a Mac Studio and a Windows PC, with
**no KVM in the video path**.

Each machine connects to both monitors on its own input. A USB switch moves the
shared peripherals. Whichever machine receives those peripherals commands both
monitors, over DDC, to select its own inputs — "pull-to-self". The KVM is gone from
the video path entirely, which is where its signal-integrity problems lived.

```
             ┌── USB-C ──────────────┐
Mac Studio ──┤                       ├── LG 45GX950A   (USB-C | DisplayPort)
             └── USB-C→DP ───────┐   │
                                 ├───┼── ASUS PG42UQ   (DisplayPort | HDMI 1)
Windows PC ──── DisplayPort ─────┘   │
           └─── HDMI 1 ──────────────┘

USB switch ──> peripherals ──> whichever machine gets them pulls both displays
```

## Layout

| Path | Purpose |
|---|---|
| `displays.toml` | **The contract.** Monitor identities, DDC method, input values, trigger devices. Both platforms read from this. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The design and its rationale — why pull-to-self, why two DDC dialects, why post-login |
| [`AGENTS.md`](AGENTS.md) | Instructions for anyone (human or agent) changing this repo, including the hard safety rules |
| `macos/` | Working implementation: `usb-watch` (IOKit) + `switch-displays.sh` (m1ddc) + LaunchAgent |
| `windows/` | Working implementation: `usb-watch.ps1` (WMI) + `switch-displays.ps1` (dxva2 for the ASUS, aimed NVAPI I2C for the LG) + Scheduled Task |

Code is not shared between platforms — macOS goes through `IOAVService`, Windows
through NVAPI and the Monitor Configuration API, with no common runtime.
`displays.toml` exists so the *values* can't silently drift apart between two
independent implementations.

## The two things that will waste your time if you forget them

**1. The LG ignores standard DDC input control.**
`VCP 0x60` writes are accepted and silently discarded, and reads always return
`0x0F` no matter what is actually displayed. Input control lives on LG's
manufacturer sidechannel: **I2C source address `0x50`, VCP `0xF4`** (`m1ddc
set input-alt`). The ASUS uses standard `VCP 0x60` normally.

**2. Never verify a switch by reading a value back.**
Reads are unreliable on *both* monitors and produced false negatives during testing:

- **PG42UQ** returns `0` for luminance, contrast, volume *and* `max luminance` —
  always, active input or not. Writes still work perfectly.
- **LG** returns real values on a settled active link, but `-7` while the link is
  inactive or renegotiating. It read `-7` immediately after a switch that had in
  fact succeeded, then recovered to `100` once settled.

Writes are fire-and-forget. Confirm visually. Corollary: don't probe immediately
after switching, or a verify-then-retry loop will fire spurious retries.

## Verified behaviour

All four cases tested from **both** machines and confirmed visually on 2026-08-30,
plus the end-to-end USB trigger driven by the real switch on the Windows side:

| Case | From the Mac | From Windows |
|---|---|---|
| ASUS → DisplayPort (show the Mac) | `input 15` ✅ | `SetVCPFeature 0x60=0x0F` ✅ |
| ASUS → HDMI 1 (show Windows) | `input 17` ✅ | `SetVCPFeature 0x60=0x11` ✅ |
| LG → USB-C (show the Mac) | `input-alt 209` ✅ | NVAPI I2C `0x50`/`0xF4=0xD1`, aimed ✅ |
| LG → DisplayPort (show Windows) | `input-alt 208` ✅ | NVAPI I2C `0x50`/`0xF4=0xD0`, aimed ✅ |

The Windows LG rows were re-verified on the aimed NVAPI transport, both directions,
confirmed visually. They previously read `lg-input-switch usbc` / `dp`; the bytes on
the wire are unchanged, but they now reach one output instead of every output.

Each machine's *pull-to-self* direction was exercised with the monitor actually
displaying the other machine — the case that matters, since the machine issuing the
command is by definition not the one being displayed. Both hosts keep their link
enumerated while the panel shows the other machine, so there is always a path to
command it home.

**In service since 2026-08-30.** Switching back and forth repeatedly between the
two machines with the real USB switch moves both monitors correctly every time, in
both directions, with no spurious switches observed.

## Monitor prerequisite: turn Auto Input Switch OFF

**On every monitor in the setup, before installing anything.** This is not
optional, and nothing in the software can compensate for it.

A monitor with this enabled moves itself to whichever input still has a signal the
moment the current one goes quiet. That directly fights a design whose entire
premise is that input selection is explicit and commanded. Sleeping either machine
makes its signal go quiet, so an enabled monitor defects to the other machine every
time you sleep.

The setting is named differently per vendor, and both were confirmed on 2026-08-30:

| Monitor | OSD setting | Required |
|---|---|---|
| LG 45GX950A | **Auto Input Switch** | Off |
| ASUS PG42UQ | **Auto Input Detection** | Off |

Verified on both monitors in both states, across real sleep cycles: **on**, the
monitor defects to the other machine when the machine driving it sleeps; **off**,
it stays where it was told. The ASUS's differently-named setting does cover
switching on signal loss, not just detection at power-on.

Nothing brings a defected monitor back on its own, because **wake is not a
trigger** — the watchers fire on USB arrival, and sleeping produces no USB event.
The monitor stays defected until the USB switch next moves.

**The trade this makes:** auto-detection is also a recovery mechanism. With it off,
a monitor that powers on to a remembered input that has no signal shows black until
you reach the OSD joystick. That is the accepted cost of deterministic switching —
know where the joystick is.

## Install

**Order matters.** Steps 1–3 are physical or hardware settings, and skipping them
produces a system that installs cleanly and then behaves strangely.

### Prerequisites

| | Needs |
|---|---|
| macOS | `brew install m1ddc`; Xcode command line tools for `clang` |
| Windows | **An NVIDIA GPU**, with only recognised monitors attached to it — the LG's sidechannel is reached through NVAPI and has no vendor-neutral equivalent, and the write lands on *every* output of that GPU, so the switcher refuses to move the LG if it sees a panel it does not know ([`windows/README.md`](windows/README.md)). Windows PowerShell 5.1 (stock). No admin rights. |

### 1. Cable each machine to each monitor

Every machine needs its **own** direct connection to **every** monitor, each on a
different input. Nothing switches video, so there is no shared cable to contend
for. This project only tells the monitors which of those inputs to show.

### 2. Put the shared peripherals through the USB switch

Whatever passes through the switch is what signals "this machine is now active."
Pick devices that enumerate on physical connection and little else — a webcam is a
good anchor, an audio interface is a weaker one. Anything wired *directly* to one
machine cannot be a trigger; here the keyboard and mouse are wired to the Windows
PC, which is why the webcam and audio interface do the signalling.

Record whatever you choose in [`displays.toml`](displays.toml), then set the same
IDs in each platform's config.

### 3. Turn auto-input off on every monitor

See [the prerequisite above](#monitor-prerequisite-turn-auto-input-switch-off). Do
this before installing, not after — with it on, the system appears to work until
the first time a machine sleeps.

### 4. Install on each machine

macOS: [`macos/README.md`](macos/README.md) — `make install`

Windows: [`windows/README.md`](windows/README.md) — `.\install.ps1`

Both install a background watcher that starts at login and is restarted if it dies.
Both are post-login by design; see [Scope](#scope).

### 5. Verify

Move the USB switch and watch **both** monitors follow. Then check the log — one
device firing and the other absent is correct, not a fault: they arrive together
and the second lands inside the debounce window.

```sh
tail -f ~/Library/Logs/displayswitch.log                      # macOS
Get-Content -Wait "$env:LOCALAPPDATA\display-switch\displayswitch.log"   # Windows
```

Confirm by looking at the screens. Never by reading a VCP value back — see the
gotchas above.

## Scope

Post-login only, on both platforms — a LaunchAgent on macOS, a Scheduled Task at
logon on Windows. Pre-login is a much larger job than it looks: `m1ddc` links
CoreGraphics and enumerates displays via `CGGetOnlineDisplayList`, which needs a
window server connection that a LaunchDaemon in session 0 does not have. Windows
hits the same wall for the same reason — session 0 has no desktop, so there is no
`HMONITOR`. See `windows/README.md` for the sketch of a CoreGraphics-free path if
this ever becomes worth building.
