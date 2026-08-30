# Windows side — NOT YET IMPLEMENTED

Design notes only. Nothing here has been built or tested.

The macOS side is deliberately finished first so the design is validated in practice
before being duplicated onto a second platform.

## What needs to exist

A background process that detects the shared USB peripherals arriving and then
commands both monitors to the Windows inputs:

| Monitor | Target input | Method |
|---|---|---|
| LG 45GX950A | DisplayPort, `0xD0` | LG sidechannel — I2C src `0x50`, VCP `0xF4` |
| ASUS PG42UQ | HDMI 1, `0x11` | Standard DDC/CI, VCP `0x60` |

Values are in [`../displays.toml`](../displays.toml). Keep them in sync — that file
exists precisely so these two implementations can't drift.

## What is already known to work

**The LG.** Standard DDC is stubbed on this panel, so the OS DDC stack is useless
for it. The working approach bypasses it entirely and injects raw I2C via **NVAPI**
(RTX 4090). Reference implementation: `github.com/meer-cha/lg-input-switch`.

The exact packets, confirmed working from Windows:

```
50 84 03 F4 00 D1 9C    switch to USB-C       (0xD1 — the Mac)
50 84 03 F4 00 D0 9D    switch to DisplayPort (0xD0 — this PC)
```

Structure: `[source_addr, 0x84, 0x03, vcp, value_hi, value_lo, checksum]`, where
checksum is the XOR of `0x6E` and all preceding bytes. Verified against m1ddc's
independent implementation on macOS — byte-identical.

**The ASUS.** Standard DDC/CI works normally from Windows, in both directions,
including while the monitor displays the other machine. The Monitor Configuration
API (`GetPhysicalMonitorsFromHMONITOR` → `SetVCPFeature`) is sufficient.

## Recommended approach: wrap, don't reimplement

Windows should be **simpler** than macOS, not harder — most of it can be assembled
from things that already work, and probably needs no compiled code at all.

**For the LG — wrap the existing tool.** `lg-input-switch` already does the NVAPI
raw-I2C injection and is confirmed working on this machine. Call it. Do **not**
hand-write NVAPI P/Invoke bindings: NVAPI dispatches through
`nvapi_QueryInterface` with magic per-function IDs, those IDs must come from a real
source rather than memory, and a wrong one calls the wrong function against a
service channel. The risk is entirely unnecessary when a working binary exists.

**For the ASUS — standard DDC, several easy options:**

- NirSoft **ControlMyMonitor** — CLI, no code:
  `ControlMyMonitor.exe /SetValue "<monitor-id>" 60 17`
- Or a short P/Invoke to `dxva2.dll`: `GetPhysicalMonitorsFromHMONITOR` →
  `SetVCPFeature(hMonitor, 0x60, 0x11)`. Well documented, low risk, ~30 lines of C#.

**For detection — likely no compiled code either:**

- PowerShell `Register-CimIndicationEvent` on `Win32_DeviceChangeEvent`, run as a
  Scheduled Task at logon; or
- A Scheduled Task triggered directly on a Kernel-PnP device-arrival event in the
  System log — zero code, though less precise about *which* device arrived.

If PowerShell proves too laggy or imprecise about device identity, then fall back to
`CM_Register_Notification` in a small C# service. Try the simple route first.

## Detection

- PowerShell `Register-CimIndicationEvent` / `Win32_DeviceChangeEvent` (start here)
- `CM_Register_Notification` with a device-interface filter (precise, needs code)
- WMI `__InstanceCreationEvent` on `Win32_USBControllerDevice` (heavier, polls)

Watch the same devices as macOS — webcam `046d:0843`, audio interface `1235:820a`.
Keyboard and mouse are wired directly to this PC's motherboard and never move.

**Port the debounce and settle logic.** It is not optional. A spurious device
arrival will yank both displays mid-session, and this desk has a documented history
of USB instability. See `../macos/usb-watch.c` for the shape.

## Startup

Post-login, matching macOS. Simplest: a **Scheduled Task** with trigger "At log on",
running in the interactive session.

A **Windows Service** would be more robust and is the only route that could ever
reach pre-login — but see below before reaching for it.

## Why pre-login is not in scope

A service runs in session 0, which has no desktop. Both DDC paths likely need a
display/session context there:

- `GetPhysicalMonitorsFromHMONITOR` needs an `HMONITOR`, i.e. a desktop.
- NVAPI display enumeration is untested in session 0 and expected to be
  problematic for the same reason.

macOS hits an identical wall: `m1ddc` links CoreGraphics and enumerates via
`CGGetOnlineDisplayList`, which needs a window server connection.

If pre-login ever becomes worth building, the macOS path is known and clean:
enumerate `DCPAVServiceProxy` entries where `Location = External` directly from
IORegistry, match by EDID product ID (LG `0x1e6d:0x9ea0`, ASUS `0x06b3:0x42e0`),
then `IOAVServiceCreateWithService` + `IOAVServiceWriteI2C` — no CoreGraphics at
all. The Windows equivalent would need investigating from scratch.

## Open questions

- Does NVAPI I2C work from a non-interactive context at all?
- Does the ASUS need the Monitor Configuration API, or can NVAPI carry both monitors
  and remove the dual-code-path?
- Confirm the ASUS is reachable over DDC on **HDMI**, not just DisplayPort — the
  macOS testing only exercised its DP input.
