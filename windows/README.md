# Windows side

A Scheduled Task runs `usb-watch.ps1`, which fires `switch-displays.ps1 windows`
when a watched USB device arrives. No compiled code and no third-party binary:
PowerShell throughout, with the NVAPI bindings inline.

Both panels use one transport -- raw I2C through NVAPI, each **aimed at the single
GPU output whose EDID identifies that panel**. Neither write is a spray; no monitor
receives the other's packet.

| Monitor | Target input | I2C source | VCP | Packet |
|---|---|---|---|---|
| LG 45GX950A | DisplayPort, `0xD0` | `0x50` (LG sidechannel) | `0xF4` | `50 84 03 F4 00 D0 9D` |
| ASUS PG42UQ | HDMI 1, `0x11` | `0x51` (standard) | `0x60` | `51 84 03 60 00 11 C9` |

Values are in [`../displays.toml`](../displays.toml). Keep them in sync -- that file
exists precisely so these two implementations can't drift.

## Requirements

- NVIDIA GPU. Both panels are driven by raw I2C through NVAPI. This is not a
  preference: the LG's input lives on I2C source `0x50`, and the Windows DDC/CI
  stack hardcodes source `0x51` and cannot express `0x50` at all, so no
  vendor-neutral API can reach it. Verified on an RTX 4090, driver 32.0.16.1062.

  The requirement predates the NVAPI transport -- the LG has always needed it, and
  the tool used before, `lg-input-switch.exe`, was itself an NVAPI program. A
  standard-DDC panel *could* be driven on any GPU through `dxva2`; supporting that
  is a generalisation question, taken up in
  [`../docs/decisions/001-nvapi-as-the-only-windows-transport.md`](../docs/decisions/001-nvapi-as-the-only-windows-transport.md).
- Windows PowerShell 5.1 (stock). No admin rights needed, at install or at run time.

## Install

```powershell
.\install.ps1              # install to %LOCALAPPDATA%, register the task, start it
.\install.ps1 -Status      # is the task registered and running?
.\install.ps1 -Logs        # tail the log
.\install.ps1 -Uninstall
```

`install.ps1` copies the two scripts and registers the task. It needs no network
access. Earlier versions downloaded a 16MB `lg-input-switch.exe` from a pinned
release; installing now deletes that binary if a previous install left one behind.

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
| ASUS -> HDMI 1 (pull here) | NVAPI I2C, src `0x51` VCP `0x60 = 0x11`, aimed | yes |
| ASUS -> DisplayPort (push to Mac) | NVAPI I2C, src `0x51` VCP `0x60 = 0x0F`, aimed | n/a (was active) |
| LG -> DisplayPort (pull here) | NVAPI I2C, src `0x50` VCP `0xF4 = 0xD0`, aimed | yes |
| LG -> USB-C (push to Mac) | NVAPI I2C, src `0x50` VCP `0xF4 = 0xD1`, aimed | n/a (was active) |

Both "pull here" cases were exercised with the monitor **displaying the Mac**, which
is the case the whole design depends on: the machine issuing the command is by
definition not the one being shown. Windows keeps its link enumerated while the
panel shows the other machine, exactly as macOS does.

All four rows were re-verified on the aimed NVAPI transport on 2026-08-30, both
monitors, both directions, confirmed visually -- including both pull-backs from an
inactive link. The ASUS pull-back is the one that had never been done this way:
HDMI DDC over NVAPI rather than `dxva2`.

**Answering the open question this file used to carry:** yes, the ASUS answers DDC
over this PC's HDMI cable, including while it is displaying its DisplayPort input.
Only its DP input had been exercised from the Mac side; HDMI 1 is now confirmed.

**Hibernate (S4) disturbs neither monitor and fires no spurious switch.** Verified
2026-08-30 across a real `shutdown -h` / resume cycle, with both panels confirmed
visually. **S3 standby hangs this machine and must not be tested** -- that, and why
the watcher is safe across a power transition, is in [`../AGENTS.md`](../AGENTS.md).

**The LG flickers briefly on every LG switch, including a no-op re-assert to the
input it is already on.** It is re-negotiating the link, and each write is sent
twice on purpose. Normal, not a fault. The ASUS no longer receives that write at
all: it is aimed at the LG's output alone.

## Components

**`switch-displays.ps1`** -- sends both writes, through one transport. Each write is
sent twice: DDC is lossy and the writes are idempotent. There are deliberately no
reads anywhere in it.

`Resolve-Panel` enumerates the GPU's connected outputs, reads each EDID, and keeps
the one whose vendor and product identify the wanted panel. It refuses on zero
matches and on more than one, because an ambiguous target cannot be aimed at, and
picking the first would reintroduce the order-dependence this repo's conventions
forbid. `Switch-Asus` and `Switch-Lg` are four lines each: resolve, describe, hand a
write to the shared `Invoke-Switch`.

The Windows display list is deliberately not consulted for that identity. In session
0 `user32` reports a *phantom* monitor rather than none, so correlating against it
matches a fiction; NVAPI is the sole source. See [`../AGENTS.md`](../AGENTS.md).
That is also why there is no `dxva2` or `user32` code here any more, and why this
script has **no desktop dependency** -- the precondition for a pre-login tier.

The `Add-Type` block is loaded once per process and stamped with a hash of its own
source. Re-running the same version in one PowerShell session reuses what is loaded;
running a *different* version refuses with an instruction to open a new shell. .NET
cannot replace a loaded type, and silently reusing the old one would mean
hand-verifying code that is not the code on disk -- the worst outcome available when
hand-verification is the only verification this hardware permits (hard rule 3). The
installed path never reaches this: the task starts a fresh `powershell.exe` per
switch.

`Test-LgBlastRadius` is gone, along with the `$LG_KNOWN_OUTPUTS` list it enforced.
It existed only because `lg-input-switch` sprayed VCP `0xF4` at every connected
output, which made an unrecognised panel a real hazard and made attaching a third
monitor stop LG switching. An aimed write has no blast radius, so both the guard and
that side effect are gone.

What replaces it is narrower and stronger, and lives at the transport rather than
the call site: `NvDdc.WriteLgInput` is the only function that can emit I2C source
`0x50`, the source byte is not a parameter, and it **throws** unless the target's
EDID manufacturer is GSM (`0x1E6D`). The sidechannel cannot be aimed at another
vendor's panel by any caller. See [`../AGENTS.md`](../AGENTS.md) hard rule 5.

Use `-WhatIf` to resolve the panels and print the exact packet bytes without sending
anything:

```powershell
.\switch-displays.ps1 windows -Only lg -WhatIf
```

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
Nothing broke, because the script never uses the index. Getting this wrong would
send LG service-channel writes to the ASUS.

**Both panels are resolved by the EDID that NVAPI reads off the GPU output** --
manufacturer and product, compared against the values in `../displays.toml`. That is
aimable, stable, and works with no desktop.

Two identity mechanisms that were tried and are *not* used, each for a specific
reason worth not rediscovering:

- **`\\.\DISPLAYn` indices** -- not stable, as above.
- **The dxva2 description string** -- useless as a key: it reports the LG as the
  generic `Generic PnP Monitor`.

The PnP interface path (`\\?\DISPLAY#AUS42E0#...`) *does* carry the EDID id and was
what the ASUS matched on until 2026-08-30. It works, but only with a desktop, so it
went when the ASUS moved onto NVAPI.

**Historical:** `lg-input-switch` was not addressable to one monitor -- it injected
on every connected output, so the ASUS also received the LG's VCP `0xF4` write. That
was confirmed harmless on the PG42UQ, once with the ASUS's own write isolated out
(`-Only lg`), which is the only way to attribute a flicker to the spray rather than
to the ASUS re-asserting its own input. That measurement is the sole evidence anyone
has about `0xF4` on a PG42UQ, which is why it is kept -- but nothing depends on it
now that the write is aimed.

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
  **per-output ids** (ASUS `0x100`, LG `0x200`) -- the aiming `lg-input-switch` threw
  away, and what the LG path now uses. Re-confirmed at boot from an at-startup task.
  In session 0, `user32` meanwhile reported one *phantom* monitor -- see
  [`../AGENTS.md`](../AGENTS.md).
- **Does the ASUS answer on the same NVAPI transport (src `0x51`, VCP `0x60`)? YES.**
  Verified visually 2026-08-30, both directions, including the pull-back from an
  inactive link. That collapsed the two identity mechanisms into one and removed the
  last `dxva2` dependency, so the switcher no longer needs a desktop at all.
- **Does either write work from session 0?** Unknown. Enumeration does, in every
  context tested; writing has only ever been done from an interactive session. This
  is the remaining gate on a pre-login tier, and phase 1 could not answer it because
  phase 1 deliberately sent no writes.
- **Does a pre-login tier get built?** The capability is all but proven; the cost is
  admin rights to register the task (measured: S4U registration is denied to a
  standard user). Nothing is built yet. See
  [`../ideas/nvapi-transport.md`](../ideas/nvapi-transport.md).
- Could NVAPI carry both monitors and remove the dual-code-path? Now looks likely
  rather than merely possible: the enumeration and identity halves are proven, and
  the write half would use the already-corroborated `NvAPI_I2CWrite`.
- Pre-login needs admin regardless: registering a scheduled task with `S4U` or a
  `SYSTEM` principal both fail with "Access is denied" for an ordinary user, while
  the `Interactive` task this installer uses does not. There is no zero-admin route.
  An `S4U` task is nonetheless preferable to a service -- it needs admin once to
  register, then runs with ordinary user rights.
