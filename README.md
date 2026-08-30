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
| `windows/` | Working implementation: `usb-watch.ps1` (WMI) + `switch-displays.ps1` (dxva2 + `lg-input-switch`) + Scheduled Task |

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
| LG → USB-C (show the Mac) | `input-alt 209` ✅ | `lg-input-switch usbc` ✅ |
| LG → DisplayPort (show Windows) | `input-alt 208` ✅ | `lg-input-switch dp` ✅ |

Each machine's *pull-to-self* direction was exercised with the monitor actually
displaying the other machine — the case that matters, since the machine issuing the
command is by definition not the one being displayed. Both hosts keep their link
enumerated while the panel shows the other machine, so there is always a path to
command it home.

## Install

macOS: see [`macos/README.md`](macos/README.md) — `make install`.

Windows: see [`windows/README.md`](windows/README.md) — `.\install.ps1`.

## Scope

Post-login only, on both platforms — a LaunchAgent on macOS, a Scheduled Task at
logon on Windows. Pre-login is a much larger job than it looks: `m1ddc` links
CoreGraphics and enumerates displays via `CGGetOnlineDisplayList`, which needs a
window server connection that a LaunchDaemon in session 0 does not have. Windows
hits the same wall for the same reason — session 0 has no desktop, so there is no
`HMONITOR`. See `windows/README.md` for the sketch of a CoreGraphics-free path if
this ever becomes worth building.
