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
| `windows/` | Design notes only — **not yet implemented** |

Code is not shared between platforms — macOS goes through `IOAVService`, Windows
through NVAPI, with no common runtime. `displays.toml` exists so the *values* can't
silently drift apart between two independent implementations.

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

All four cases tested and confirmed visually on 2026-08-30:

| Case | Method | From an inactive link |
|---|---|---|
| ASUS → DisplayPort (pull to Mac) | `input 15` | ✅ |
| ASUS → HDMI 1 (push to Windows) | `input 17` | ✅ |
| LG → USB-C (pull to Mac) | `input-alt 209` | ✅ |
| LG → DisplayPort (push to Windows) | `input-alt 208` | ✅ |

"Inactive link" is the case that matters: the machine issuing the command is by
definition not the one being displayed. The Mac's link stays enumerated while the
monitor shows the other machine, so there is always a path to command it home.

## Install

macOS: see [`macos/README.md`](macos/README.md) — `make install`.

Windows: not implemented. See [`windows/README.md`](windows/README.md).

## Scope

Post-login only, on both platforms. Pre-login is a much larger job than it looks —
`m1ddc` links CoreGraphics and enumerates displays via `CGGetOnlineDisplayList`,
which needs a window server connection that a LaunchDaemon in session 0 does not
have. Windows hits the same wall for the same reason. See `windows/README.md` for
the sketch of a CoreGraphics-free path if this ever becomes worth building.
