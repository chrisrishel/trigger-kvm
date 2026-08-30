# Windows side

A Scheduled Task runs `usb-watch.ps1`, which fires `switch-displays.ps1 windows`
when a watched USB device arrives. No compiled code: PowerShell plus one pinned
third-party binary for the LG.

| Monitor | Target input | Method |
|---|---|---|
| LG 45GX950A | DisplayPort, `0xD0` | LG sidechannel -- I2C src `0x50`, VCP `0xF4`, via `lg-input-switch.exe` |
| ASUS PG42UQ | HDMI 1, `0x11` | Standard DDC/CI, VCP `0x60`, via `dxva2.dll` |

Values are in [`../displays.toml`](../displays.toml). Keep them in sync -- that file
exists precisely so these two implementations can't drift.

## Requirements

- NVIDIA GPU. The LG path injects raw I2C through NVAPI; there is no vendor-neutral
  route to the sidechannel. Verified on an RTX 4090, driver 32.0.16.1062.
- Windows PowerShell 5.1 (stock). No admin rights needed, at install or at run time.

## Install

```powershell
.\install.ps1              # install to %LOCALAPPDATA%, register the task, start it
.\install.ps1 -Status      # is the task registered and running?
.\install.ps1 -Logs        # tail the log
.\install.ps1 -Uninstall
```

`install.ps1` downloads `lg-input-switch` from a pinned release and verifies its
SHA256. The binary is not vendored -- it is 16MB of third-party code.

Log: `%LOCALAPPDATA%\display-switch\displayswitch.log`

## Manual use

```powershell
.\switch-displays.ps1 windows            # pull both monitors here
.\switch-displays.ps1 mac                # push both to the Mac
.\switch-displays.ps1 windows -Only asus # move one monitor only
```

`-Only lg|asus|both` exists because moving both at once can take away the display
your terminal is on. Use it when testing.

## Verified behaviour

All four cases tested from Windows and confirmed visually on 2026-08-30, plus the
end-to-end USB trigger:

| Case | Method | From an inactive link |
|---|---|---|
| ASUS -> HDMI 1 (pull here) | `SetVCPFeature 0x60 = 0x11` | yes |
| ASUS -> DisplayPort (push to Mac) | `SetVCPFeature 0x60 = 0x0F` | n/a (was active) |
| LG -> DisplayPort (pull here) | `lg-input-switch dp` | yes |
| LG -> USB-C (push to Mac) | `lg-input-switch usbc` | n/a (was active) |

Both "pull here" cases were exercised with the monitor **displaying the Mac**, which
is the case the whole design depends on: the machine issuing the command is by
definition not the one being shown. Windows keeps its link enumerated while the
panel shows the other machine, exactly as macOS does.

**Answering the open question this file used to carry:** yes, the ASUS answers DDC
over this PC's HDMI cable, including while it is displaying its DisplayPort input.
Only its DP input had been exercised from the Mac side; HDMI 1 is now confirmed.

## Components

**`switch-displays.ps1`** -- sends both writes. The ASUS goes through the Monitor
Configuration API (`GetPhysicalMonitorsFromHMONITOR` -> `SetVCPFeature`); the LG
shells out to `lg-input-switch.exe`. Each write is sent twice: DDC is lossy and the
writes are idempotent. There are deliberately no reads anywhere in it.

**`usb-watch.ps1`** -- `Register-CimIndicationEvent` on `Win32_DeviceChangeEvent`,
an extrinsic WMI event, so there is no polling interval. That event does not say
*which* device changed, so each one is followed by a targeted `Win32_PnPEntity`
query (~40ms) to establish identity. Push latency, exact identity, no elevation.

Three safety behaviours, ported from `../macos/usb-watch.c`:

- **debounce** (3.0s) -- ignore arrivals within N seconds of the last fire. This is
  not theoretical: on the first live test the Focusrite arrived at `01:49:46` and
  fired, and the webcam followed moments later and was correctly swallowed.
- **settle** (0.75s) -- after an arrival, wait, then confirm the device is *still*
  present. Appear-then-vanish was a glitch, not a switch.
- **edge-triggered** -- fires only on absent -> present. Devices already plugged in
  at startup never fire.

**`install.ps1`** -- Scheduled Task at logon, interactive session, `RunLevel
Limited`. Explicitly clears `StopIfGoingOnBatteries`, which defaults on and would
otherwise kill the watcher on a brief UPS blip.

## Watched devices

Kept in sync with [`../displays.toml`](../displays.toml):

| Device | ID | Note |
|---|---|---|
| Logitech Webcam C930e | `046d:0843` | Preferred anchor -- a UVC camera rarely re-enumerates spuriously |
| Focusrite Clarett+ 2Pre | `1235:820a` | Weaker anchor -- audio interfaces re-enumerate on driver reloads and power events |

Both confirmed present on this machine when the USB switch is pointed here.

**Match the full VID+PID, never the vendor alone.** The keyboard and mouse are
Logitech too (`VID_046D`, `PID_C547`) and are *always* present, because they are
wired directly to this PC's motherboard and do not pass through the USB switch. A
vendor-only match would fire continuously.

## Traps specific to Windows

**Do not address monitors by index or by description.** On this machine
`\\.\DISPLAY1` is the **ASUS** and `\\.\DISPLAY2` is the LG, and dxva2 reports the
LG's description as the useless generic string `Generic PnP Monitor`. Getting this
wrong sends LG service-channel writes to the ASUS. `switch-displays.ps1` resolves
by the EDID id embedded in the PnP interface path instead:

```
\\?\DISPLAY#AUS42E0#5&aaaaaaaa&0&UID4352#{e6f07b5f-...}
             ^^^^^^^ matched on this
```

**`lg-input-switch` is not addressable to one monitor.** See `../AGENTS.md` -- it
injects on every connected output, so the ASUS also receives the LG's VCP `0xF4`
write. Confirmed harmless on the PG42UQ, but it is why the LG path cannot be made
selective without forking the tool.

**Keep `.ps1` files ASCII-only.** Windows PowerShell 5.1 reads a `.ps1` without a
BOM as ANSI, so a UTF-8 em dash in a comment becomes a parse error tens of lines
away from anything that looks wrong.

## Scope: post-login only

The task runs at logon in the interactive session, matching macOS. A Windows
Service would run in session 0, which has no desktop, so
`GetPhysicalMonitorsFromHMONITOR` would have no `HMONITOR` to work from. NVAPI
display enumeration in session 0 is untested and expected to be problematic for the
same reason. See [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

## Still open

- Does NVAPI I2C work from a non-interactive context at all? (unexplored; only
  matters if pre-login ever becomes worth building)
- Could NVAPI carry both monitors and remove the dual-code-path? Possible in
  principle, but it would mean sourcing more NVAPI function ids, and the current
  ASUS path works and is safe.
