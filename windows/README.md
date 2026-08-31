# Windows side

A Scheduled Task runs `event-watch.ps1`, which fires `trigger-kvm.ps1 pull`
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
.\install.ps1              # user tier -- no admin. Install, register, start.
.\install.ps1 -Tier s4u    # pre-login tier -- NEEDS ADMIN to register
.\install.ps1 -Status      # which tier is installed, and what it therefore covers
.\install.ps1 -Logs        # tail the log
.\install.ps1 -Uninstall
```

### Two tiers

Pick by what you are willing to grant. They are mutually exclusive by construction
-- one task name, so installing either replaces the other.

| | user (default) | s4u |
|---|---|---|
| Admin to install | **no** | **yes**, once |
| Elevated at run time | no | **no** |
| Runs | at logon, your session | at startup, session 0, as you |
| From logon onward | yes | yes |
| While **locked** | **yes** | yes |
| Before first login after boot | no | **yes** |
| After a full logoff | no | **yes** |

The locked row is the one that surprises people, and it is why the default tier is
enough for most days: locking does not end your session, so the watcher is still
alive and the displays still follow. The s4u tier buys the two genuinely
uncovered cases. The one that stings is a rebooted PC sitting at a login screen you
cannot see, because the monitors are still showing the other machine.

`-Status` reports the tier *and* what it covers, deliberately -- a tier name on its
own invites you to guess the capability, and the capability is the entire point of
having tiers.

**The tier is a property of the host, not of the switcher.** All tier logic lives in
`install.ps1`. Neither `trigger-kvm.ps1` nor `event-watch.ps1` knows or asks which
tier it is running under. If either ever needs to, the abstraction is wrong.

`install.ps1` copies the two scripts and registers the task. It needs no network
access. Earlier versions downloaded a 16MB `lg-input-switch.exe` from a pinned
release; installing now deletes that binary if a previous install left one behind.

Log: `%LOCALAPPDATA%\trigger-kvm\trigger-kvm.log`, rotated by the watcher at
startup once it passes 1MB (`-MaxLogBytes`), keeping one generation as `.log.1`.

## Triggers

**Anything that can run `trigger-kvm.ps1 pull` is a trigger.** The watcher and the
switcher are separate processes and that command line is the entire interface
between them, so a hotkey binding, a Stream Deck button, a scheduled task, or an
SSH command all work today with no support from this tool.

What ships is one trigger: `event-watch.ps1`, which fires on **device presence** and
is what `install.ps1` registers. There is deliberately no plugin system or trigger
registry — the process boundary already is one, and a second abstraction on top
would earn nothing.

**Its mechanism is not USB-specific, but that does not mean every transport fits
it.** `Win32_PnPEntity` enumerates Bluetooth, PCI and Thunderbolt too — measured
here, USB is only 44 of ~300 PnP entities. So the *query* is generic and USB is only
the ID pattern matched.

**Bluetooth, however, would not work by changing that pattern**, and it is worth
recording why, because the reasoning looks sound right up until you check it. The
watcher's model is "a PnP node exists only while the device is attached", so
presence == connected and an absent→present edge means arrival. For USB that holds.
For Bluetooth it does not: a *paired* device keeps its node whether or not it is
connected. Measured on this machine —

```
BTHENUM\DEV_0011223344FF   Present=True   DEVPKEY_Bluetooth_LastConnectedTime = 2025-11-07
BTHENUM\DEV_<iphone>       Present=True   DEVPKEY_Bluetooth_LastConnectedTime = 2023-07-07
```

— a pair of AirPods last connected ten months ago and an iPhone last connected three
years ago both still report `Present=True`. There is even a
`DEVPKEY_DeviceContainer_AlwaysShowDeviceAsConnected = True` on them. The presence
map would never change, so no edge would ever fire and the trigger would silently
never work.

What *does* track connection is the downstream function nodes — the AirPods'
`SWD\MMDEVAPI\...` audio endpoints are `Present=False` right now while the parent is
`True`. But those are opaque GUIDs, differ by device class, and on this machine the
same service GUIDs exist twice (a stale `LOCALMFG&0002` set alongside a live
`VID&0001004C_PID&2027` set), so matching them is guesswork.

The correct route is **another presence source inside the same watcher**, not a
second watcher process. The debounce is in-memory and per-process, so two watchers
would each hold their own window and both fire when a USB device and a Bluetooth
device arrive together -- the exact double-fire the `Global\` mutex prevents, and
which that mutex would in fact block by stopping the second watcher from starting.
Only "is it present" and "tell me when that changes" are transport-specific; the
edge, debounce, settle and fire logic is shared and must stay that way.

That is the line between the two kinds of boundary here: the watcher and the
switcher are separate *processes* because they share no mutable state; two presence
sources share the debounce clock and the presence map, so they belong in one.

**It is not free, though.** `Windows.Devices.Enumeration.DeviceWatcher` with
`System.Devices.Aep.IsConnected` is the right API and its types load in PowerShell
5.1 -- but `Register-ObjectEvent` on it fails with *"Windows PowerShell cannot
subscribe to Windows RT events"*, and `FindAllAsync` timed out through the `AsTask`
bridge. A Bluetooth source needs a small inline C# shim to catch the WinRT event and
re-raise it as a plain .NET event. That is the same `Add-Type` pattern the NVAPI
transport already uses, so it fits the codebase -- but it is real work.

The config keys stay flat anyway — `trigger.device`, `trigger.debounce`,
`trigger.settle`. Nesting them under a transport was tried and reverted: it
advertised a capability that does not exist, and a malformed id already fails loudly
(`expected VVVV:PPPP`), so there was no silent failure for the extra structure to
prevent. When a second transport actually lands, that is the moment to decide how
ids get qualified — and the installer already warns rather than silently reverting
when it meets a key name it doesn't know.

The timings sit at `trigger.*` rather than under any transport for a reason that
does matter: **one debounce has to cover every trigger.** Two independent windows
could not dedupe against each other — the same failure that forced the
single-instance mutex to become machine-wide. At this level that holds by
construction, with no level at which a second one could be written.

**A trigger runs `pull`, and only `pull`.** Never wire one to a scene. A scene names
inputs on hardware this machine cannot observe, which go stale the moment a cable
moves over there; keeping scenes out of the trigger path means a stale scene can
only ever spoil a command you typed and are watching, never an automatic switch to
a dead input. That rule is easier to hold because there is no framework inviting you
to parameterise it.

## Discovery

```powershell
.\install.ps1 -Discover      # what's attached, in the form the config wants
.\trigger-kvm.ps1 list       # just the displays
```

`-Discover` lists connected displays with their EDID ids, and USB devices attached
**right now** — which is the filter doing most of the work, since you install on the
machine currently holding the peripherals, so whatever moves is by definition
present. Hubs and host controllers are dropped, and the several PnP nodes one
physical device produces are collapsed to one row per `VID:PID`, keeping the
best-named entry.

It deliberately still shows your keyboard and mouse. They share a vendor id with the
webcam on this desk, and seeing that is how you avoid the vendor-only match that
would fire constantly.

## Configuration

`%LOCALAPPDATA%\trigger-kvm\config` — generated by `install.ps1`, **safe to edit by
hand**, and never overwritten by re-running the installer. It sits beside the log
rather than in the program directory so uninstalling doesn't throw away a
configuration you spent time getting right.

```
display.lg.vendor  = 0x1E6D     # EDID manufacturer id
display.lg.product = 0x9E9D     # EDID product id
display.lg.name    = LG 45GX950A
display.lg.method  = lg-alt     # standard | lg-alt
display.lg.self    = 0xD0       # the input where THIS machine is. Required.

trigger.device   = 046d:0843,1235:820a
trigger.debounce = 3.0
trigger.settle   = 0.75

scene.mac.lg   = 0xD1           # manual only -- the trigger never reads scenes
```

Flat `key = value` with `#` comments, deliberately not TOML or JSON: this is read on
every device arrival and must not depend on a parser being present. The whole reader
is a dozen lines, and the macOS side can do the same job with one `sed`.

**Which edits take effect when.** Display and scene changes apply at the next
switch, because the switcher reads the file each time. Trigger changes need
`install.ps1` re-run — those are baked into the scheduled task at registration, and
the installer reads them back out of the config rather than from its own defaults.

**It fails closed, in ways worth knowing:**

- An unparseable EDID id refuses rather than defaulting. `[int]$null` is `0` in
  PowerShell, so a typo'd vendor would otherwise become a silent match against
  `0x0000` — a write aimed at the wrong panel is the failure this project spends
  most of its effort avoiding.
- A scene naming three displays but carrying values for two moves **none** of them.
  Every value is resolved before anything is sent. A half-applied arrangement is
  worse than none: it leaves the desk in a state nobody configured, and you have to
  work out which half landed.
- `method = lg-alt` grants nothing. `NvDdc.WriteLgInput` still refuses any panel
  whose EDID manufacturer is not GSM, so putting `lg-alt` on a Dell makes the write
  throw — it does not make it happen. Verified by test.

## Manual use

```powershell
.\trigger-kvm.ps1 pull               # pull every configured monitor here
.\trigger-kvm.ps1 to mac             # apply the saved scene "mac"
.\trigger-kvm.ps1 pull -Only asus    # one monitor only
.\trigger-kvm.ps1 pull -WhatIf       # resolve and print packets, send nothing
```

`-Only <label>` takes a label from your config and exists because moving every
monitor at once can take away the display your terminal is on. Use it when testing.

`pull` and `to` are separate verbs on purpose, and the separation is a safety
property rather than a style choice. `pull` uses only `self` values -- the inputs
where *this* machine is -- so it holds no belief about any other machine and nothing
another machine does can invalidate it. `to` applies a scene, which names inputs on
hardware this machine cannot observe. **The trigger can only ever run `pull`**, so a
scene that has gone stale can spoil a command you typed and are watching, never an
automatic switch.

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

**`trigger-kvm.ps1`** -- sends both writes, through one transport. Each write is
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
.\trigger-kvm.ps1 pull -Only lg -WhatIf
```

**Single instance is enforced machine-wide, not per session.** `event-watch.ps1` takes
`Global\trigger-kvm-usb-watch`. `Local\` would be scoped to one session, so a
logon watcher in session 1 and an at-startup watcher in session 0 would each take
their own, both arm, and both fire on the same arrival -- and the debounce is
per-process, so it cannot dedupe across them. Measured 2026-08-30: an unelevated
interactive process can create a `Global\` mutex here, and a second process sees it
held. `Local\` remains a fallback for a token without `SeCreateGlobalPrivilege`. If
the global name exists but cannot be opened, the watcher stands down rather than
falling back -- something owns it under another identity, and falling back would
recreate the exact double-fire this prevents.

**`event-watch.ps1`** -- `Register-CimIndicationEvent` on `Win32_DeviceChangeEvent`,
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

**Only one ever runs.** `event-watch.ps1` holds a named mutex
(`Local\trigger-kvm-usb-watch`) and exits immediately if another instance has
it. This matters more than it looks: the watcher is a *grandchild* of the task, so
stopping the task kills the launcher but leaves the watcher running. Without the
mutex, every reinstall and every self-heal tick would stack another watcher, and
each one would fire the switcher on the same arrival -- the debounce is per-process
and cannot dedupe across them. `install.ps1` also explicitly clears stale watchers,
so an upgrade cannot leave the old code holding the mutex.

A consequence worth knowing when testing by hand: running `event-watch.ps1` yourself
while the task is running will exit at once with `another usb-watch is already
running`. Stop the task first.

Both scripts also take `-LogFile` and append to it themselves, so nothing depends
on shell redirection -- which is what let the `cmd.exe` wrapper go away.

To stop it deliberately:

```powershell
.\install.ps1 -Uninstall     # unregister the task and clear any running watcher
Stop-ScheduledTask -TaskName trigger-kvm   # just this session; self-heal will restart it
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
`trigger-kvm.ps1 windows` that had been logging `on \\.\DISPLAY1` for the ASUS
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
.\nvapi-probe.ps1 -LogFile C:\ProgramData\trigger-kvm\nvapi-probe.log
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
- **Does a WRITE work from session 0? YES.** Measured 2026-08-30 from an unelevated
  on-demand S4U task (`sessionId=0 interactive=False`): it pushed the LG to the Mac,
  held 12s, and pulled it back, **both moves confirmed visually**. Enumeration
  working there did not imply this, and the two had to be tested separately -- phase
  1 deliberately sent no writes. This settles the pre-login design: a plain
  at-startup task drives the displays directly, with no relay.
- **Do WMI device notifications reach a session-0 watcher? YES.** Measured
  2026-08-30 from an unelevated S4U task (`sessionId=0 interactive=False`): 45
  `Win32_DeviceChangeEvent` indications received in 90s, and `Win32_PnPEntity`
  presence queries returned correct results there too. This was the last thing that
  could have made the s4u tier fail *silently* -- the switcher was already proven in
  session 0, but the detector was not, and a watcher that runs and never fires is
  the worst failure shape available. The distinction that made it plausible either
  way: `WM_DEVICECHANGE` is a window message and needs a desktop, while
  `Win32_DeviceChangeEvent` is a WMI extrinsic event from the Winmgmt service. Only
  the latter is used here, and it is session-independent.
- **Does a pre-login tier get built?** Built as opt-in (`-Tier s4u`); the remaining
  step is a reboot acceptance test. It is a permissions question rather than a
  technical one. It needs admin to register (measured: `S4U` and `SYSTEM`
  principals both fail with "Access is denied" for an ordinary user, while the
  `Interactive` task this installer uses does not). That changes the project's
  current "no admin needed" posture, so it is a deliberate call, not a default.
  `S4U` is the tier to prefer: admin once to register, then ordinary user rights at
  runtime, and no elevated code on the switch path.
- **Note what it would actually add. Locking is already covered.** Confirmed
  2026-08-30: with the screen locked, flipping the USB switch still pulls the
  displays back, because the session and its watcher are still alive. A pre-login
  tier buys the two narrower cases -- **before the first login after a boot** and
  **after a full logoff**. The first is the one that stings: a rebooted PC sitting at
  a login screen you cannot see, because the monitors are still showing the Mac.
