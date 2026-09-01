# Measurements

Dated observations on real hardware and real platforms, kept because a rule in
`AGENTS.md` or a platform's `AGENTS.md` rests on each. The rules live there;
this is the evidence, so the rule can be short and the reasoning can still be
checked. Newest first within each section.

**A plausible inference is not a measurement.** Three claims were once written
into the instructions as measured and were wrong, each an inference from a real
observation: "IOBluetooth never returns" (an unanswered permission prompt sat
behind it), "a LaunchAgent can never get Bluetooth permission" (the prompt had not
arrived within the 15 seconds observed), and "reading the displays needs a
logged-in session" (it does not, at all). Run the thing in the context you are
making a claim about; if you cannot, say that instead of concluding.

## Detectors

**2026-08-30, Windows -- one USB plug is dozens of events.** Plugging a single
device in generated 32 `Win32_DeviceChangeEvent` indications in about three
seconds, and unplugging it another 13. The event carries no device identity, so
each costs a `Win32_PnPEntity` query. A Bluetooth connect produces about 3.

**2026-08-30, Windows -- PnP presence is "paired" for Bluetooth.** A pair of
earbuds whose `DEVPKEY_Bluetooth_LastConnectedTime` was ten months earlier, and a
phone whose was three years earlier, both reported `Present=True` and carried
`DEVPKEY_DeviceContainer_AlwaysShowDeviceAsConnected = True`. Their downstream
function nodes (`SWD\MMDEVAPI\` audio endpoints) did read `Present=False`, but
they are opaque GUIDs, differ by device class, and appeared twice under two
service-id forms.

**2026-08-30, Windows -- WMI reaches session 0.** From an unelevated S4U task: 45
`Win32_DeviceChangeEvent` indications in 90 s, and `Win32_PnPEntity` presence
queries worked there too.

**2026-08-31, macOS -- IOBluetooth works once TCC permission is granted.** One
probe binary, run from a terminal and from a LaunchAgent: 10 paired devices with
connected state, no run loop needed, clean exit -- after the per-binary prompt was
approved, which arrived minutes after the first call. `system_profiler
SPBluetoothDataType -xml` answered on the very first attempt with no prompt, in
about 60 ms.

**Both platforms -- only one device is ever logged.** The Focusrite wins and the
webcam is never logged, on both platforms; the second arrival falls inside the
debounce window.

## Sleep, wake and the monitors

**2026-08-30, macOS -- a real `pmset sleepnow` / wake cycle produced zero log
entries.** The Mac Studio keeps USB powered through sleep. One cycle, one desktop.

**2026-08-30, Windows -- hibernate (S4).** The watcher came back as the same live
process with its `$present` map intact; the Focusrite's relay was audible as bus
power returned; no edge, nothing fired. Restarted across the transition instead,
it logged `armed (2 already present, not firing)`. `DEVPKEY_Device_LastArrivalDate`
read `03:28:57` (boot) for both devices before and after.

**2026-08-30, Windows -- S3 hung the machine.** Power light blinking, displays
off, then fans up with no video, keyboard, mouse or RDP; hard reboot. No crash
dump, no bugcheck. The Scheduled Task is `WakeToRun: False`; the watcher's last
activity was three minutes earlier. The System log holds zero `Kernel-Power 42`
and zero `Power-Troubleshooter 1` events back to 2026-01-25, so no sleep cycle
has ever completed on this machine. `powercfg /a` offers only S3 and Hibernate and
reports Hybrid Sleep unavailable because "the hypervisor does not support this
standby state", with VBS running under HVCI strict mode.

**2026-08-30 -- the ASUS defected during sleep.** It lost the Mac's signal and its
auto-input feature moved it to the other live input; nothing pulled it back
because wake is not a trigger. Both monitors were then tested in both states
across real sleep cycles: enabled, the monitor defects; disabled, it holds. LG
*Auto Input Switch*, ASUS *Auto Input Detection* -- the ASUS one does cover
switching on signal loss despite the wording.

## Display identity

**2026-08-30, Windows -- session 0 reports one phantom monitor.** `nvapi-probe.ps1`
as SYSTEM and as an unelevated S4U task: `EnumDisplayMonitors` returned **1** in
each case, not DDC-capable, while NVAPI enumerated both real panels with their
real EDIDs. NVAPI also **writes** from session 0: the S4U task moved the LG in
both directions with no desktop.

**2026-08-30, Windows -- `NV_GPU_DISPLAYIDS.isActive` varies over time.** `False`
for both panels at 15:51 and `True` for both at 16:13 in the same interactive
session, no deliberate change between. `isConnected` was stable throughout.

**2026-08-30, Windows -- the display indices swapped.** `DISPLAY1`=ASUS /
`DISPLAY2`=LG became `DISPLAY1`=LG / `DISPLAY2`=ASUS across a hard reboot and a
hibernate cycle (not observed separately). dxva2 describes the LG as `Generic PnP
Monitor`. Nothing broke, because the switcher resolves by EDID.

**The LG's EDID product id is per-input.** `0x9e9d` (Windows, DP), `0x9e9f` (Mac,
USB-C), `0x9ea0` (Mac, through the old KVM), each stable for its own host. The
ASUS reports `0x42e0` everywhere.

**2026-08-31, macOS -- display identity needs no session.** From a LaunchDaemon
with `UserName` set and no logged-in session: IOKit display identity worked with
no CoreGraphics, `m1ddc display list` worked, and a full `trigger-kvm pull` ran
as uid 501 with both writes sent.

## The LG service channel

**2026-08-30, Windows -- what `0xF4` does to a PG42UQ.** With the old spraying
tool and the ASUS write isolated out (a `-Only lg` run, so the spray was the only
traffic on the wire), the ASUS ignored `SetVCP 0xF4`: no flicker, no setting
change. The only evidence anyone has on this, for that specific panel.

## Logs

**2026-08-31, macOS -- copy-truncate under launchd leaves no hole.** A throwaway
agent writing a line a second through `StandardErrorPath`, truncated mid-flight,
resumed at offset 0 with zero NUL bytes in the file.

## PowerShell console and language

**2026-08-31 -- `[Console]::CursorLeft` clamps.** After `Write-Host ('x' * $w)
-NoNewline` on a `$w`-wide buffer, `CursorLeft` reads `$w - 1`, the same as after
`$w - 1` characters; and writing into the last column wraps. A first measurement
via `[Console]::Write` read "a full-width line plus a newline advances exactly one
row" -- true of that API and not of `Write-Host`.

**2026-08-31 -- a simple function swallows unknown named arguments.**
`Test-Simple -A hello -ThisName world` binds `$A`, leaves `-ThisName world` in
`$args`, and does not throw; a `[CmdletBinding()]` function throws `A parameter
cannot be found that matches parameter name 'ThisName'`.
