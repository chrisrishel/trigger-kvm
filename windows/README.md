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

**Hibernate (S4) disturbs neither monitor and fires no spurious switch.** Verified
2026-08-30 across a real `shutdown -h` / resume cycle, with both panels confirmed
visually. **S3 standby hangs this machine and must not be tested** -- that, and why
the watcher is safe across a power transition, is in [`../AGENTS.md`](../AGENTS.md).

**The LG flickers briefly on every LG switch, including a no-op re-assert to the
input it is already on.** It is re-negotiating the link, and each write is sent
twice on purpose. Normal, not a fault. The ASUS does not flicker when it receives
the LG's `0xF4` spray -- confirmed with the ASUS's own write isolated out.

## Components

**`switch-displays.ps1`** -- sends both writes. The ASUS goes through the Monitor
Configuration API (`GetPhysicalMonitorsFromHMONITOR` -> `SetVCPFeature`); the LG
shells out to `lg-input-switch.exe`. Each write is sent twice: DDC is lossy and the
writes are idempotent. There are deliberately no reads anywhere in it.

Before every LG switch it runs `Test-LgBlastRadius`, which enumerates the monitors
on the NVIDIA adapter and **refuses** the switch if any of them is outside the known
set (`GSM9E9D`, `AUS42E0`). Because `lg-input-switch` sprays VCP `0xF4` at every
connected output, an unrecognised panel would silently receive the LG's
service-channel packet; refusing is the only way to be sure it does not. A *missing*
known panel is not a hazard and only logs a `note:`. Attach a third monitor and LG
switching stops until you add its id to `$LG_KNOWN_OUTPUTS` -- by design. See
[`../AGENTS.md`](../AGENTS.md) hard rule 5.

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

## How it runs, and why it is hard to close by accident

There is **no window anywhere** -- no console, no taskbar entry, nothing to click.
Three separate mechanisms, because each covers a different failure:

**No console is ever allocated.** The task's action is `wscript.exe launcher.vbs`,
not `powershell.exe`. PowerShell is a console-subsystem binary: Windows gives it a
console *before* `-WindowStyle Hidden` can take effect, so running it straight from
a logon task can flash a console at every login and leaves a closeable window.
`wscript.exe` is GUI-subsystem and starts the watcher hidden from the first
instruction. `launcher.vbs` is generated by `install.ps1`, the same way the macOS
`Makefile` generates the LaunchAgent plist -- don't edit it, re-run the installer.

The launcher waits on the watcher rather than returning, so Task Scheduler still
reports the task as `Running` and its restart-on-failure settings still apply.

**It comes back if it dies.** `-AtLogOn` alone means that if the watcher is ever
killed -- Task Manager, a crash, a stray `Stop-Process` -- it stays dead until the
next logon, and you would only discover it when the displays quietly stopped
following the USB switch. A second trigger re-runs the task every minute;
`MultipleInstances IgnoreNew` makes that a no-op while it is alive, so the
steady-state cost is a process launch that exits immediately.

That no-op is also why `install.ps1 -Status` shows a last-run result of
`2147946720` / `0x800710E0` -- "The operator or administrator has refused the
request" -- during **normal** operation. It is Task Scheduler's code for a trigger
that fired while an instance was already running, i.e. `IgnoreNew` doing its job.
Expect it whenever the watcher is healthy; it is not a failure to chase.

That trigger is the *only* thing that brings it back. The task's `RestartCount` /
`RestartInterval` settings do not: killing the watcher leaves the task `Ready`
rather than failed, and no restart occurred in 180s of watching. Measured
2026-08-30, kill to running again: **51s** at a 1-minute interval, against 205s
when the interval was 5 minutes.

This is the one place Windows is meaningfully behind macOS, where launchd's
`KeepAlive` respawns in **0.01s** -- measured 2026-08-30 by `kill -9` on the
watcher, not estimated. The gap against this side's 51s is four orders of
magnitude, though both are recoveries from a failure that should not happen. Closing that fully would mean making
`launcher.vbs` a supervising loop, which is deliberately not done: stopping the
task kills the launcher but leaves the watcher (see below), so a loop would spin
relaunching a watcher that exits immediately on the mutex. A minute of downtime
after an unobserved failure is the better trade.

**Only one ever runs.** `usb-watch.ps1` holds a named mutex
(`Local\display-switch-usb-watch`) and exits immediately if another instance has
it. This matters more than it looks: the watcher is a *grandchild* of the task, so
stopping the task kills the launcher but leaves the watcher running. Without the
mutex, every reinstall and every self-heal tick would stack another watcher, and
each one would fire the switcher on the same arrival -- the debounce is per-process
and cannot dedupe across them. `install.ps1` also explicitly clears stale watchers,
so an upgrade cannot leave the old code holding the mutex.

A consequence worth knowing when testing by hand: running `usb-watch.ps1` yourself
while the task is running will exit at once with `another usb-watch is already
running`. Stop the task first.

Both scripts also take `-LogFile` and append to it themselves, so nothing depends
on shell redirection -- which is what let the `cmd.exe` wrapper go away.

To stop it deliberately:

```powershell
.\install.ps1 -Uninstall     # unregister the task and clear any running watcher
Stop-ScheduledTask -TaskName display-switch   # just this session; self-heal will restart it
```

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

**Do not address monitors by index or by description. The indices are not stable.**
They were `\\.\DISPLAY1` = ASUS and `\\.\DISPLAY2` = LG for all of this project's
early testing, and then on 2026-08-30 they **swapped**: the same
`switch-displays.ps1 windows` that had been logging `on \\.\DISPLAY1` for the ASUS
began logging `on \\.\DISPLAY2`, across a hard reboot and a hibernate cycle.
Nothing broke, because the script never uses the index. dxva2 is no help either --
it reports the LG's description as the useless generic string `Generic PnP
Monitor`. Getting this wrong sends LG service-channel writes to the ASUS.
`switch-displays.ps1` resolves by the EDID id embedded in the PnP interface path
instead:

```
\\?\DISPLAY#AUS42E0#5&aaaaaaaa&0&UID4352#{e6f07b5f-...}
             ^^^^^^^ matched on this
```

**`lg-input-switch` is not addressable to one monitor.** See `../AGENTS.md` -- it
injects on every connected output, so the ASUS also receives the LG's VCP `0xF4`
write. Confirmed harmless on the PG42UQ, including once with the ASUS's own write
isolated out (`-Only lg`), which is the only way to attribute a flicker to the spray
rather than to the ASUS re-asserting its own input. It is why the LG path cannot be
made selective without forking the tool, and why `Test-LgBlastRadius` refuses when
an unrecognised panel is attached.

**Keep `.ps1` files ASCII-only.** Windows PowerShell 5.1 reads a `.ps1` without a
BOM as ANSI, so a UTF-8 em dash in a comment becomes a parse error tens of lines
away from anything that looks wrong.

## Scope: post-login only

The task runs at logon in the interactive session, matching macOS. A Windows
Service would run in session 0, which has no desktop, so
`GetPhysicalMonitorsFromHMONITOR` would have no `HMONITOR` to work from. NVAPI
display enumeration in session 0 is untested and expected to be problematic for the
same reason. See [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

## `nvapi-probe.ps1` -- a read-only diagnostic

```powershell
.\nvapi-probe.ps1                              # print what NVAPI can see
.\nvapi-probe.ps1 -LogFile C:\ProgramData\display-switch\nvapi-probe.log
```

Enumerates GPUs, connected displays and each display's EDID **through NVAPI only**,
and prints a `user32 EnumDisplayMonitors` count beside it as a control. It exists to
answer whether monitors can be identified in a context that has no desktop, which is
the precondition for any pre-login work.

**It performs no writes.** `NvAPI_I2CWrite` is deliberately not resolved anywhere in
the file, so it cannot be called even by accident; nothing is sent to source address
`0x50`; no VCP value is read or written. `NvAPI_GPU_GetEDID` reads the EDID block
from the GPU, which is neither the service channel nor a VCP read. Safe to run
repeatedly, in any context, with nothing to confirm visually.

Function ids and struct layouts come from [SimpleKVM](https://github.com/fiddyschmitt/SimpleKVM)
(MIT), with `NvAPI_Initialize` and `NvAPI_EnumPhysicalGPUs` independently
corroborated by `lg-input-switch`.

## Still open

- **Does NVAPI work from a context with no desktop? YES, for enumeration.** Measured
  2026-08-30 in three contexts -- interactive, SYSTEM in session 0, and an unelevated
  non-interactive S4U task. All three enumerated both panels with correct EDIDs and
  **per-output ids** (ASUS `0x100`, LG `0x200`), which is the aiming
  `lg-input-switch` throws away. In session 0, `user32` meanwhile reported one
  *phantom* monitor -- see [`../AGENTS.md`](../AGENTS.md).
- **Does `NvAPI_I2CWrite` work? Unknown -- it has never been called here.**
  Enumeration working does not imply writing works. This is the next thing to
  establish, in a normal session first and confirmed visually.
- Could NVAPI carry both monitors and remove the dual-code-path? Now looks likely
  rather than merely possible: the enumeration and identity halves are proven, and
  the write half would use the already-corroborated `NvAPI_I2CWrite`.
- Pre-login needs admin regardless: registering a scheduled task with `S4U` or a
  `SYSTEM` principal both fail with "Access is denied" for an ordinary user, while
  the `Interactive` task this installer uses does not. There is no zero-admin route.
  An `S4U` task is nonetheless preferable to a service -- it needs admin once to
  register, then runs with ordinary user rights.
