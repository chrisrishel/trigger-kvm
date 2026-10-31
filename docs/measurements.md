# Measurements

Dated observations on real hardware and real platforms, kept because a rule in
`AGENTS.md` or a platform's `AGENTS.md` rests on each. The rules live there;
this is the evidence, so the rule can be short and the reasoning can still be
checked. Newest first within each section.

Device serials, display UUIDs and host-specific instance components are
replaced with consistent labels in angle brackets. Their equality or change
is the observation; the identifying bytes are unnecessary. Numeric protocol
values and documented placeholder serials remain literal.

**A plausible inference is not a measurement.** Four claims were once written
into the instructions as measured and were wrong, each an inference from a real
observation: "IOBluetooth never returns" (an unanswered permission prompt sat
behind it), "a LaunchAgent can never get Bluetooth permission" (the prompt had not
arrived within the 15 seconds observed), "reading the displays needs a
logged-in session" (it does not, at all), and "S4U / Limited proves the process
is unelevated" (a native control's process token was elevated). Run the thing in the context you are
making a claim about; if you cannot, say that instead of concluding.

| section | what it settles | rules resting on it |
|---|---|---|
| [Naming a device](#naming-a-device) | what each platform can read off a USB device, and the cost of reading it | `specs/configure.md` 7.1, `specs/detector.md` 4.1, `windows/AGENTS.md` (cfgmgr32) |
| [Detectors](#detectors) | edges, bursts, session 0, the paired-arrival case, Bluetooth presence | `specs/detector.md`, `AGENTS.md` "one device in the log", `macos/AGENTS.md` (TCC) |
| [Sleep, wake and the monitors](#sleep-wake-and-the-monitors) | nothing fires on sleep/wake; the monitors defect with auto-input on; S3 hangs the PC | `AGENTS.md` "wake is not a trigger", `windows/AGENTS.md` (hibernate only) |
| [Display identity](#display-identity) | EDID ids, serials, NVAPI ids and GDI names across reboots, cable moves and a driver update | `AGENTS.md` "resolve by EDID", "product id per input" |
| [Intel DDC route](#intel-ddc-route) | the framebuffer I2C route reaches both panels from an Intel Mac | decision 004 |
| [The dxva2 route](#the-dxva2-route-on-the-onboard-intel-gpu-windows) | dxva2 switches a standard panel on any adapter and sees nothing in session 0 | decision 003 |
| [DDC reads](#ddc-reads) | read-back values lie on both panels | `AGENTS.md` hard rule 2 |
| [The LG service channel](#the-lg-service-channel) | what `0xF4` did to the ASUS when it was sprayed | `AGENTS.md` hard rule 5 |
| [Asking whether a watcher is running](#asking-whether-a-watcher-is-running) | the lock answers; a process count cannot on Windows | `specs/status.md` 2 |
| [Logs](#logs) | copy-truncate under launchd leaves no hole | `macos/AGENTS.md` |
| [PowerShell console and language](#powershell-console-and-language) | session-boundary blindness, PATH kinds, console clamping, argument passing | `windows/AGENTS.md` |
| [Release validation and privacy](#release-validation-and-privacy) | installed-candidate checks and the scope/limits of the publication audit | `CONTRIBUTING.md`, `TODO.md` |

## Naming a device

**2026-09-04, Windows -- three trigger candidates were called `USB Input
Device`, and two of them could never travel.** On the reference desk the
Triggers list offered `usb:046d:c547`, `usb:0b05:19af` and `usb:0b05:879e` under
that one name. They are, respectively, a Logitech LIGHTSPEED receiver carrying a
G915 X keyboard **and** a mouse, the motherboard's AURA LED controller, and the
ROG STRIX LC AIO cooler. So the two that are soldered into the case were
indistinguishable from the one holding the peripherals.

**The old rule chose the WORST available name, and did so by design.** It ranked
a device's PnP nodes by how specific each one's device *class* was -- `HIDClass`
scored 2, plain `USB` scored 4, lowest wins -- as a proxy for how good that
node's name would be. The proxy is inverted: HID nodes are precisely the ones
Windows names generically. For `046d:c547` the `HIDClass` node (`USB Input
Device`) beat a sibling `USB` node already reading `G915 X LIGHTSPEED TKL`.

**`DEVPKEY_Device_BusReportedDeviceDesc` names all three**, because it is the USB
`iProduct` string the DEVICE reports rather than the name its INF driver hands
it: `AURA LED Controller`, `ROG STRIX LC`, `USB Receiver`.

**How you ask for it decides whether this is possible at all.** Same property,
same 42 USB nodes, same unelevated session:

| route | time | usable |
|---|---|---|
| `Get-PnpDeviceProperty` | **70,148 ms** (~200 ms per call) | no |
| `cfgmgr32!CM_Get_DevNode_PropertyW` by P/Invoke | **6 ms** (0.14 ms per node) | yes |
| registry `Enum\USB\...\Properties\{540b947e-...}\0004` | 106 ms | **no -- 0 of 115 instance keys readable unelevated**, and `configure` runs unelevated |

A 10,000x spread between two ways of reading one property. The cmdlet's cost is
its CIM plumbing, not the underlying API.

**HID children carry the role, for free.** The `HID\VID_...&PID_...` nodes have
class `Mouse` or `Keyboard`; the USB pass skips them because it matches `USB\`
only. `usb:046d:c547` presents both -- which is also how the list can show that
one receiver serves a keyboard and a mouse, so they are ONE vendor+product pair
and cannot be triggered on separately.

**A name beginning `USB ` is describing the bus, not the device.** True of every
generic name observed here -- `USB Input Device`, `USB Composite Device`,
`USB Receiver`, `USB Audio` -- and of no manufacturer's own string on this desk.
Preferring against that prefix is what promotes `Realtek USB Audio` over
`USB Audio` and `G915 X LIGHTSPEED TKL` over `USB Receiver`, with no list of weak
names to maintain. Whole rewritten discovery, end to end: **355 ms**, including
the `Add-Type` compile.

**2026-09-04, Windows -- what a per-device token would cost the detector.**
`windows/AGENTS.md` warns that one physical plug is dozens of presence sweeps, so
per-device work inside a sweep multiplies. Simulated at 32 sweeps against the 22
PnP nodes of `046D:C547`, comparing today's `Test-UsbPresent` against the same
query plus a container read and a bus-name read per node:

| | per sweep | per plug (32 sweeps) |
|---|---|---|
| baseline, one WQL query | 23.22 ms | 743 ms |
| plus token matching | 24.59 ms | 787 ms |
| **added** | **1.4 ms** | **44 ms** (~6%) |

**The CIM query already dominates**, and the `cfgmgr32` property reads are noise
beside it -- so a token needs no cache. The prior estimate of ~100 ms was
arithmetic and was pessimistic; this replaces it.

Two things worth keeping from the same run. The baseline is **23 ms per sweep for
ONE watched device**, so a two-device config already spends ~1.5 s per plug on
presence alone -- existing behaviour, not introduced by anything here. And the
two receivers resolve to distinct tokens (`g915-x-lightspeed-tkl`,
`lightspeed-receiver`) while **`usb-receiver` appears under BOTH** -- a live
demonstration that a token has to be chosen for uniqueness among the devices
sharing an id, not merely taken.

**2026-09-06, macOS -- IOKit gives ONE name, and it is already the good one; the
two LIGHTSPEED receivers are indistinguishable here in a way they are not on
Windows.** Read off every attached USB device with `ioreg -a -r -c
IOUSBHostDevice -l`, unelevated, no device opened.

| what Windows needed | what macOS reports |
|---|---|
| two name sources, the driver's and the device's | **one** -- `USB Product Name` and `kUSBProductString` are the same string on all 15 devices, and it IS the `iProduct` string |
| the second source rescued `USB Input Device` | nothing to rescue: the names are already `Logitech Webcam C930e`, `Clarett+ 2Pre`, `LG Monitor Controls`, `USB Receiver` |
| roles from `HID\` child device classes | roles from HID usage pages on the child nodes -- `1/2` mouse, `1/6` keyboard -- readable as properties, no open |

**So revision 10 is nearly free here, and the second-source finding does not
transfer.** Two devices report no name at all (`1e4e:720b`, and one node of
`043e:9a8a`), which is a missing string rather than a bad one.

**The part that matters, and it goes the other way.** Both `046D:C547` receivers
are on this Mac, at `locationID` 1245184 and 1314816:

| discriminator | Windows | macOS |
|---|---|---|
| product string | `G915 X LIGHTSPEED TKL` vs `LIGHTSPEED Receiver` -- **distinct** | `USB Receiver` vs `USB Receiver` -- **identical** |
| USB serial | absent on both | **absent on both** |
| role | both present mouse and keyboard | both present `1/2` AND `1/6` -- identical |
| port | instance id | `locationID` -- **the only thing that differs** |

The hoped-for answer was that macOS might see a serial where Windows sees none.
**It does not.** `kUSBSerialNumberString` is surfaced and real -- the webcam
reports `<webcam-serial>`, the Clarett `<interface-serial>`, `LG Monitor Controls` `<lg-ascii-serial>`
-- so the route exists; it is simply absent on the devices where it would decide
something. And a serial is not automatically unique anyway: the two Apple hubs
(`05ac:8009`, `05ac:800a`) both report `<shared-hub-serial>`.

**Consequence for revision 12, measured rather than assumed:** on this desk macOS
can write NO token for `usb:046d:c547`, because `detector.md` §4.1 requires a
value held by exactly one of the devices sharing the id and there is none. The
`where` suffix is not a nicety here, it is the only route -- the opposite of
Windows, where a token resolves it and `where` is never consulted. Nothing about
the FORMAT changes; what changes is which half of it this platform leans on.

## Detectors

**2026-09-02, Windows -- the round trip: BOTH panels, in both directions, with
nobody logged in.** The 01:00 run below left exactly one thing unwitnessed --
the Mac's video leg to the LG was unplugged, so only the ASUS ever had anywhere
to come back from. Re-run 30 minutes later with that cable connected. Same
session-0 watcher, deliberately untouched in between (pid 14008, armed
2026-09-01 22:36:36, still alive afterwards and still the only one on the
machine).

Winlogon logged the logoff at 01:30:02 and the next logon at 01:30:52. Inside
that window, with no interactive user on the machine at any point, the owner
flipped the USB switch to the Mac, **both panels followed it there**, waited,
flipped back, and **both came back to the PC**. Both halves are the owner's, by
eye; neither is a log's to make (hard rule 3). So the whole round trip fits in
the 50 s between a logoff and the next logon.

The log carries only the PC's half of that, and only as far as the writes:
`arrival usb:1235:820A` at 01:30:40, settled 0.75 s, `pull` fired at 01:30:41,
LG `0xF4 = 0xD0` and PG42UQ `0x60 = 0x11` emitted. **One fire, not two.**

**The flip TO the Mac left no line at all, and cannot.** A departure is
`Write-Verbose` (`windows/event-watch.ps1`), so this log can never show the
peripherals leaving; the evidence that they left is the re-arrival implying a
removal. Correlating a flip against the log therefore needs the OS's PnP
timestamps, every time.

**Real edge again, killed the same way.** Every watched device's
`DEVPKEY_Device_LastArrivalDate` reads 01:30:39-40, so the peripherals
physically re-enumerated when the watcher said they did rather than
`Test-UsbPresent` manufacturing an edge out of failed queries.

**And the settle-absorbs reading holds under a harder case.** Here PnP stamps
`1235:820A` and `046D:0843` in the SAME second, 01:30:40 -- yet the log still
names only `1235:820A`. Second-granularity timestamps cannot separate the two
arrivals, but the sweep did, which is the entry below's mechanism rather than a
coincidence of its one-second gap.

**2026-09-02, Windows -- the boot tier fires at an empty logon screen.** The one
untested step in the pre-login path: every earlier session-0 result was taken
with a user logged in, so session 0 had no desktop but the machine was not empty
of a session. The watcher under test was the session-0 one armed 2026-09-01
22:36:38 (`sessionId=0 interactive=False lock=Global`); it survived a full logoff
and was still alive and holding the mutex afterwards.

Winlogon logged the logoff at 01:00:14 and the next logon at 01:01:00. Between
them, with no interactive user on the machine, the watcher logged `arrival
usb:1235:820A`, settled 0.75 s, and fired `pull` at 01:00:49; both writes were
emitted (LG `0xF4 = 0xD0`, PG42UQ `0x60 = 0x11`).

Two claims, kept apart, because only one of them is a log's to make. The log
proves the watcher fired and the switcher emitted both writes with no session on
the machine. The owner separately confirmed **by eye** that the displays came
back to the PC -- the half no log can carry (hard rule 3).

**The panel that demonstrably MOVED is the ASUS**, and the run says so honestly:
the Mac's Thunderbolt-to-USB-C cable -- its video leg to the LG -- was
disconnected at the time, so when the peripherals reached the Mac only the ASUS
followed. The LG had therefore never left the PC, and the PC's write to it was a
re-assert rather than a visible move. The measurement stands either way, because
what was under test is whether a session-0 watcher fires and drives a panel with
nobody signed in, and a panel that was genuinely displaying the other machine
came back. State it this way rather than "both panels moved", which the eye did
not witness. **The round-trip entry above closed that gap 30 minutes later**, so
the caveat is this run's, not the boot tier's.

**Incidentally, the Mac failed closed exactly as designed.** With no link to the
LG at all, zero enumerated outputs identify as the LG, and hard rule 5 makes zero
a refusal -- so the LG was left alone rather than aimed at on a guess. Inferred
from the cabling and the rule, not read from the Mac's log.

**The arrival was real, not an artefact of logoff churn.** Worth killing rather
than assuming: `Test-UsbPresent` reads a failed CIM query as an absence, so two
bad sweeps across a logoff would manufacture an absent -> present edge and yank
the displays with nothing physical behind it. Every watched device's
`DEVPKEY_Device_LastArrivalDate` reads 01:00:47-49, so the peripherals really did
re-enumerate when the watcher said they did. (That property does not conflict
with the hibernate rule below: `LastArrivalDate` tracks a PnP arrival, which a
switch flip is, and not bus power cycling, which is what it fails to track.)

**2026-09-02, Windows -- the second watched device IS on the switch, and is
swallowed by the SETTLE, not the debounce.** This answers the open question in
the entry below, which could not say whether `usb:046D:0843` was on the switch at
all. On this flip the OS recorded `1235:820A` arriving at 01:00:48 and
`046D:0843` at 01:00:49, so both are on it and both arrive. The log still named
only `1235:820A`, and the mechanism is worth being exact about: the sweep at
01:00:48 saw the webcam still absent, so it was not in `$arrived`; the settle
re-check a second later reassigns `$present` **wholesale**, adopting the webcam
as baseline. Its arrival never reaches the debounce check at all -- there is no
later edge left to reject.

So the paired arrival macOS asked about does happen here. It is absorbed one step
earlier than that entry assumed, and correctly: the fire it would have caused is
the one the debounce exists to suppress.

**2026-09-01, Windows -- the paired-arrival case does not appear in this log at
all.** macOS saw two watched devices arrive 6 s apart on one flip and run `pull`
twice, and asked whether the same happens here. Over 24 fires spanning
2026-08-30 to 2026-09-01, EVERY arrival names the same device,
`usb:1235:820A`; the other configured device, `usb:046D:0843`, never produces an
arrival edge, though both are reported present at every arm. Two pairs of fires
fall inside a minute (8 s and 30 s apart, both at 01:50-01:51 on 2026-08-31) and
both arrivals in each pair name that SAME device, so they are repeated flips
during a test session rather than a second device arriving late.

What the log CANNOT say is whether the second device is on the switch at all:
departures, and arrivals rejected by the debounce, are `Write-Verbose` rather
than logged, deliberately, because one plug is dozens of events. So this is
evidence that the macOS behaviour is not reproducing here, not evidence that it
cannot. No shared fix is warranted from this side.

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

**2026-08-30, Windows -- WMI reaches session 0.** From an S4U task: 45
`Win32_DeviceChangeEvent` indications in 90 s, and `Win32_PnPEntity` presence
queries worked there too. Its process-token elevation was not recorded; the
2026-10-30 control invalidates inferring that from the task's Limited setting.

**2026-08-31, macOS -- IOBluetooth works once TCC permission is granted.** One
probe binary, run from a terminal and from a LaunchAgent: 10 paired devices with
connected state, no run loop needed, clean exit -- after the per-binary prompt was
approved, which arrived minutes after the first call. `system_profiler
SPBluetoothDataType -xml` answered on the very first attempt with no prompt, in
about 60 ms.

**Both platforms -- only one device is ever logged.** The Focusrite wins and the
webcam is never logged, on both platforms; the second arrival falls inside the
debounce window.

**2026-08-31, Windows -- three routes to Bluetooth connection state, ruled out
before `bthprops.cpl`.** Recorded so none is re-tried:

| route | result |
|---|---|
| widen the PnP match to `BTHENUM\` | presence there means PAIRED: a device keeps its node for years after it last connected, so no arrival edge ever happens |
| `Register-ObjectEvent` on the WinRT `BluetoothLEDevice` | `Windows PowerShell cannot subscribe to Windows RT events` |
| `Add-Type -ReferencedAssemblies` a `.winmd` | `0x80131047`, the metadata file cannot be loaded |

The classic API answers directly: `BluetoothGetDeviceInfo` fills
`BLUETOOTH_DEVICE_INFO.fConnected`, which is distinct from `fRemembered`.

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
standby state", with VBS running under HVCI strict mode. Use hibernate to
re-test anything here -- and from a bash-flavoured shell that is `shutdown -h`,
not `/h`, which MSYS rewrites into a path.

**2026-08-30 -- the ASUS defected during sleep.** It lost the Mac's signal and its
auto-input feature moved it to the other live input; nothing pulled it back
because wake is not a trigger. Both monitors were then tested in both states
across real sleep cycles: enabled, the monitor defects; disabled, it holds. LG
*Auto Input Switch*, ASUS *Auto Input Detection* -- the ASUS one does cover
switching on signal loss despite the wording.

## Display identity

**2026-10-30, Windows -- read-only identity check after a reboot on NVIDIA
616.64.** Windows reported its last boot on 2026-10-13, after the recorded live
driver update. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
windows/nvapi-probe.ps1` initialized successfully and enumerated both reference
panels. Comparing by EDID manufacturer/product, both panels' `displayId`,
`outputId` and product matched the documented baseline. Raw identifiers remain
in the private validation record. This closes the deferred post-reboot identity
check; it does not establish that this candidate starts at boot or that a panel
physically switches. No VCP read or display write was performed.

**2026-09-05, Windows -- one of the two panels here reports an EDID serial of
`0x01010101`.** `trigger-kvm list -Raw` on the reference desk:

| panel | EDID | connector | EDID serial | outputId |
|---|---|---|---|---|
| LG ULTRAGEAR+ | `1E6D:9E9D` | DisplayPort | `<lg-edid-serial>` | `0x00000200` |
| ASUS PG42UQ | `06B3:42E0` | HDMI | `0x01010101` | `0x00000100` |

**What is measured is the value, not what it means.** `0x01010101` has the shape
of a placeholder, and the obvious inference is that a second PG42UQ would read
the same -- but there is only one of them here, so that is an inference and this
file's preamble is about exactly this. What can be said without a second unit:
the LG's serial is a plausible per-unit value and stable across all four of its
inputs (see below), while the ASUS's is not plausible as one.

Only EDID bytes 12-15 are parsed (`windows/trigger-kvm.ps1:512-513`). **Descriptor
tag `0xFF`, the ASCII serial-number string, is not read by this code** -- it is
where a real per-unit serial lives when the numeric field is a placeholder, and
**both panels here carry one.** Measured 2026-09-05 from
`WmiMonitorID.SerialNumberID`, which surfaces that descriptor: ASUS
`<asus-ascii-serial>`, LG `<lg-ascii-serial>`. So `0x01010101` is a property of this ASUS's
numeric FIELD, not of the panel. This section previously called that unmeasured
while the 2026-09-01 entry below had already recorded the ASUS string in passing;
the two are now in step.

Two limits on what that licenses. Descriptor `0xFF` is **optional** in the EDID
standard, so "both panels here have one" is n=2 and says nothing about panels
generally -- and nothing here measures whether two units of one model carry
*different* strings, which is the only property that would matter for telling
twins apart. And WMI is not available to the switcher's boot tier
(`windows/AGENTS.md`: NVAPI is the only identity source it may use), so reading
this in shipping code means parsing the descriptor out of the EDID block NVAPI
already returns, not calling WMI.

The `outputId` values above are a **pre-reboot baseline**, taken so the question
"is `OutputId` a port identity or a per-boot handle?" could be answered by
re-reading them after a restart. **It has been -- see the next entry.** They come
from `NvAPI_SYS_GetGpuAndOutputIdFromDisplayId` and are what `NvAPI_I2CWrite` is
already aimed at (`windows/trigger-kvm.ps1:245`, `:493`).

**2026-09-05, Windows -- `OutputId` and `displayId` both survived a cold reboot,
unchanged.** Re-read after a restart at 19:59:57, by two independent paths: the
switcher's own resolution via `trigger-kvm pull -WhatIf` at 20:03 (which prints
the packets it would send and sends nothing) and `nvapi-probe.ps1` at 20:05
(read-only; it never resolves `NvAPI_I2CWrite`). The restart was a real
one: `Kernel-Boot` event 27 reports **boot type `0x0`**, a cold boot -- not `0x1`
(hybrid, i.e. fast startup) and not `0x2` (resume from hibernate), either of
which restores the previous kernel session instead of re-enumerating, and would
have made the reading meaningless.

| panel | connector | displayId | outputId |
|---|---|---|---|
| LG ULTRAGEAR+ | DisplayPort | `0x80061082` | `0x00000200` |
| ASUS PG42UQ | HDMI | `0x80061083` | `0x00000100` |

Every value identical to the baseline. **On this machine `OutputId` is a port
identity, not a per-boot handle**, and `displayId` is equally stable. Three
further observations widen the span, with all four values agreeing throughout:

- **The same four values were recorded by the 2026-08-30 probe runs**, the
  last of them 16:13 -- the runs the `isActive` entry below is drawn from. Three cold boots are logged since: 16:21
  that same day, 2026-09-01 22:36, and 2026-09-05 19:59.
- **The ASUS left the card entirely and came back to the same values.** Its PC
  cable moved to the motherboard HDMI output on 2026-09-01 and back to the 4090
  afterwards, restoring the PnP instance path exactly (see the 2026-09-01 entry
  below). Its NVAPI ids are what they were before the move -- while over that same
  event its GDI name did *not* return, taking a third value (`\\.\DISPLAY1` ->
  `\\.\DISPLAY7` -> `\\.\DISPLAY3`). One identifier stable across it, one not.
- **Neither id tracks enumeration order.** On 2026-09-01, with the ASUS on the
  Intel output, the LG was the only connected NVIDIA display and enumerated as
  `display[0]` carrying `displayId=0x80061082 outputId=0x00000200`. Today it
  enumerates as `display[1]` carrying the same two values. The index moved; the
  ids did not.

**What this does NOT measure.** The machine has one GPU (`gpus=1` in every probe
run), so nothing here exercises the case that separates the two fields:
`outputId` is a single-bit mask scoped to ONE GPU, so on a two-card machine
GPU0's first port and GPU1's first port both read `0x00000100`, whereas NVAPI
documents `displayId` as system-unique. That difference is structural and comes
from NVIDIA's documentation, not from a reading here. **The driver-version
question was settled later the same day, two entries below: 610.62 -> 616.64
changed none of it.** Still unmeasured: another machine, a second card, and
moving a cable between two sockets on the same one (`TODO.md` carries the last).

**2026-09-05, Windows -- the pre-driver-update baseline, and the driver version
nothing here had ever recorded.** Every NVAPI reading in this file was taken
against a driver version that was not written down -- including all three
entries above. This is the first that names one, so that the next update can be
a *measurement* rather than a change of unknown scope. Taken 23:42, read-only,
on the boot recorded above.

| | value |
|---|---|
| NVIDIA driver | **610.62** (WDDM `32.0.16.1062`, dated 2026-06-10) |
| VBIOS | `95.02.18.80.89` |
| Intel driver | `32.0.101.7088`, dated 2026-06-16 |
| struct versions accepted | `NV_GPU_DISPLAYIDS` `0x00030010` (16 bytes), `NV_EDID` `0x00030110` (272 bytes) |
| GPUs / connected displays | 1 / 2 |

| panel | displayId | outputId | connector | reachable by | PnP instance |
|---|---|---|---|---|---|
| ASUS `06B3:42E0` | `0x80061083` | `0x00000100` | HDMI | nvapi, dxva2 | `DISPLAY\AUS42E0\5&<adapter-instance-a>&0&UID4352_0` |
| LG `1E6D:9E9D` | `0x80061082` | `0x00000200` | DisplayPort | nvapi, dxva2 | `DISPLAY\GSM9E9D\5&<adapter-instance-a>&0&UID4353_0` |

The ASUS's PnP instance path is character-for-character the one recorded before
its 2026-09-01 cable move (below). The same label denotes the same measured instance component throughout.

`trigger-kvm list -Raw` at the same moment, which is the form an implementation
actually consumes -- the trailing field is the attached-panel count added at
revision 13:

```
06B3|42E0|AUS|HDMI|01010101|PG42UQ|nvapi,dxva2|1
1E6D|9E9D|GSM|DisplayPort|<lg-edid-serial>|LG ULTRAGEAR+|nvapi,dxva2|1
```

GDI device names at the same moment, recorded because they are the identifier
measured NOT to survive re-enumeration: `\\.\DISPLAY1` primary at 3413x1440,
`\\.\DISPLAY2` at 2560x1440 -- both logical sizes at 150% scaling. **Which panel
is which is inferred from the resolution, not read** (5120x2160 is the LG,
3840x2160 the ASUS), so this row is weaker evidence than the ones above and is
here only because the pairing is the thing that has moved before.

What a comparison after the next update should answer, and in what order of
consequence, is in `../TODO.md`. The first such comparison follows.

**2026-09-05, Windows -- a driver upgrade moved the GDI names and left every
NVAPI identity untouched.** NVIDIA **610.62 -> 616.64** (WDDM `32.0.16.1062` ->
`32.0.16.1664`, dated 2026-06-10 -> 2026-08-23), read at 23:50 against the
baseline above.

**Windows replaced the driver LIVE: `LastBootUpTime` is unchanged at 19:59:56.**
The driver stack did genuinely tear down and re-enumerate -- the GDI names below
are the proof -- so this is a real driver-version reading. What it is not is a
reboot *on* the new driver; see the gap at the end.

**Unchanged, every one of them:** `displayId` (ASUS `0x80061083`, LG
`0x80061082`), `outputId` (`0x00000100`, `0x00000200`), connector, EDID ids, both
descriptor `0xFF` serials, both PnP instance paths, `reachable by` (`nvapi,
dxva2` on both), `gpus=1`, and the struct versions NVAPI accepts
(`NV_GPU_DISPLAYIDS` `0x00030010`, `NV_EDID` `0x00030110`). VBIOS unchanged too,
as firmware should be.

**Changed: the GDI device names. `\\.\DISPLAY1` and `\\.\DISPLAY2` became
`\\.\DISPLAY10` and `\\.\DISPLAY11`.** That is the finding. In ONE event, within
one boot, with nothing else altered, the NVAPI ids held perfectly still while the
GDI names moved by nine. The 2026-08-30 reboot swap said the same thing with more
variables in play; this says it cleanly. It is the strongest evidence in this
file for resolving by EDID and never by index -- and for preferring `displayId`
over `\\.\DISPLAYn` as a per-port key, which is the choice
`../ideas/telling-two-identical-monitors-apart.md` records.

**The switch still works, confirmed by eye.** The ASUS was sent to the Mac and
pulled back, `--only` in both directions, watched by the owner -- including the
pull back from an INACTIVE link, which is the case that matters. Recorded on a
person's word, per hard rule 3; no success code is evidence here.

**The watcher fired nothing across the install -- the first observation of it.**
The log's last entry before the upgrade is 22:43:57 and its next falls after it:
the display re-enumeration storm produced no arrival edge. Presence is watched on
USB and not on displays, and this is a measurement of that rather than the
reasoning for it. The session-0 watcher armed at 20:00:38 came through the
upgrade as a live process.

**The gap this leaves.** A reboot ON the new driver has not happened. Reboot
alone was measured stable this morning, and a driver change alone is stable here,
so the combination is very likely stable as well -- but that is inference, and
this file's preamble exists for exactly that distinction. `../TODO.md` carries
it.

**2026-08-30, Windows -- session 0 reports one phantom monitor.** `nvapi-probe.ps1`
as SYSTEM and as an S4U task: `EnumDisplayMonitors` returned **1** in
each case, not DDC-capable, while NVAPI enumerated both real panels with their
real EDIDs. NVAPI also **writes** from session 0: the S4U task moved the LG in
both directions with no desktop. The S4U process-token elevation was not recorded.

**2026-08-30, Windows -- `NV_GPU_DISPLAYIDS.isActive` varies over time.** `False`
for both panels at 15:51 and `True` for both at 16:13 in the same interactive
session, no deliberate change between. `isConnected` was stable throughout.

**2026-08-30, Windows -- the display indices swapped.** `DISPLAY1`=ASUS /
`DISPLAY2`=LG became `DISPLAY1`=LG / `DISPLAY2`=ASUS across a hard reboot and a
hibernate cycle (not observed separately). dxva2 describes the LG as `Generic PnP
Monitor`. Nothing broke, because the switcher resolves by EDID.

**The LG's EDID product id is per-INPUT, and not per-host.** Four consecutive
values on the one panel: `0x9e9d` (Windows, DP), `0x9e9e` (Intel Mac, HDMI 1),
`0x9e9f` (Mac, USB-C), `0x9ea0` (Mac, through the old KVM). It was once recorded
here as "each stable for its own host", which left open whether the id followed
the input or the machine. On 2026-09-01 the Intel MacBook, on the LG's USB-C
input, read `0x9e9f` -- the same value the Mac Studio reads on that same input.
So the input decides it, and a host still may only use the value it measures on
its own input.

Around it: the EDID *serial* (`<lg-edid-serial>`) is stable across all of them, while
the EDID's own length is not -- 384 bytes on USB-C, 512 on HDMI 1. And because
`CGDisplayCreateUUIDFromDisplayID` derives from the product id, the UUID m1ddc
keys on is per-input as well (`<usb-c-uuid>` USB-C, `<hdmi1-uuid>` HDMI 1). The
ASUS reports `0x42e0` everywhere, and its UUID was correspondingly identical
across two readings on one input.

**2026-08-31, macOS -- display identity needs no session.** From a LaunchDaemon
with `UserName` set and no logged-in session: IOKit display identity worked with
no CoreGraphics, `m1ddc display list` worked, and a full `trigger-kvm pull` ran
as uid 501 with both writes sent.

**2026-09-08, Windows -- over Remote Desktop, `user32` presents the RDP virtual
display and NONE of the physical panels.** Measured from a session opened with
mstsc while both monitors were pointed at the Mac:

```
qwinsta            session 1 = rdp-tcp#28 (Active, rishe), session 3 = console (Conn)
SM_REMOTESESSION   1                    <- a remote session
$env:SESSIONNAME   Console              <- STALE. Do not use it to detect one
SM_CMONITORS       1
EnumDisplayMonitors  1 -> \\.\DISPLAY1, GetNumberOfPhysicalMonitorsFromHMONITOR ok=True n=1
Win32_VideoController  NVIDIA RTX 4090 (OK), Microsoft Remote Display Adapter (OK),
                       Intel UHD 770 (OK), Virtual Desktop Monitor (Error)
```

`trigger-kvm list` in that session reported BOTH panels, `reachable by nvapi`
only: NVAPI is unaffected because it reads the GPU's outputs rather than the
desktop. `dxva2` identified nothing (`DXVA2 enumerated: nothing`) and the switch
REFUSED -- so this fails by REFUSING, where the same root cause in session 0
fails by MIS-RESOLVING onto a phantom (2026-08-30, above). The EDID gate is what
turns both into a refusal rather than a mis-aimed write.

**What this adds to the session-0 finding**: "needs a desktop" is too weak.
`dxva2` needs a LOCAL CONSOLE session. A remote one is a logged-in desktop by
every other measure and still has none of the real monitors in it.

## Intel DDC route

All taken 2026-09-01 on a MacBook Pro 16" (`MacBookPro16,1`, Core i9-9880H,
macOS 15.3.2 / 24D81) against this desk's two panels, with
`macos/intel-ddc-probe`. That instrument enumerates; with `--i2c-read` it sends
ONE standard `GetVCP 0x60` on source `0x51`; with `--set-asus-input` ONE standard
`SetVCP 0x60` to an AUS panel; and with `--set-lg-input` ONE `SetVCP 0xF4` on the
service source `0x50` to a GSM panel. Every value comes from a named allowlist
copied from `displays.toml` -- no number a caller supplies is expressible, so
nothing here sweeps or walks a channel. The MacBook's own screen held the
terminal throughout, so hard rule 4 was never in play.

This machine has two GPUs: the Intel UHD 630 drives the built-in panel and the
AMD Radeon Pro 5500M drives externals, so the framebuffer class here is
`AMDRadeonX6000_AmdRadeonFramebuffer`. The 13" 2019 model drives externals from
the Intel GPU instead and is a different driver; none of this was measured there.

**The framebuffer I2C route exists on Intel and reaches both panels, direct and
through Apple's HDMI adapter.** Three cablings, three well-formed DDC/CI replies:

| Cabling | Panel / input | Reply | `result` |
|---|---|---|---|
| USB-C to USB-C, direct (DP Alt Mode) | LG, USB-C | `6E 88 02 00 60 00 00 12 00 0F C9` | `0x0` |
| Apple USB-C Digital AV Multiport Adapter (`05AC:1460`) | LG, HDMI 1 | `6E 88 02 00 60 00 00 12 00 0F C9` | `0x0` |
| the same adapter | ASUS, HDMI 2 | `6E 88 02 00 60 00 00 05 00 12 C3` | `0x0` |

The adapter is an old one, contemporary with the 2019 machine, and its picture
was visibly degraded on the LG -- wrong colour, wrong resolution, a TMDS
bandwidth limit against a 5120x2160 panel. **DDC was unaffected**: the reply
through it was byte-identical to the direct DP Alt Mode link. Picture quality and
the display data channel are independent, and a bad picture is not evidence
against the route.

**The ASUS answers DDC on an input it is not displaying, on this route too.**
With the adapter left on HDMI 2 and the panel switched back to DisplayPort, it
replied `6E 88 02 00 60 00 00 05 00 0F DE` -- current `0x0F`, DisplayPort, which
is the input it was in fact showing. So its DDC responder is panel-global, not
per-input. This is the case a switcher actually depends on, since a switch always
addresses a monitor that is currently showing the other machine; every other
reading in this section was taken on an actively displayed input.

**Read VALUES still behave as hard rule 2 says, and the two panels differ.** The
LG returned `0x0F` on both of its cablings while genuinely on USB-C and then on
HDMI 1 -- the stub `displays.toml` documents, confirmed now from a third host and
a different OS route. The ASUS reported its true input twice and tracked a real
change (`0x12` on HDMI 2 while showing HDMI 2, `0x0F` after being switched to
DisplayPort). That does not license reading back: it is two correct reads on the
panel that never needed the sidechannel, while the panel that does need it lied
both times. The existing "the PG42UQ answers 0 to everything" note was measured
on luminance, contrast, volume and max luminance; `0x60` is not those. Even here
the ASUS's `max` field came back `0x0005`, nonsense for input select, so the
current field was right while the max field beside it was garbage.

**The route WRITES, and a write framed on it moved a real panel in both
directions.** A standard `SetVCP 0x60` through `IOI2CSendRequest` to the ASUS on
HDMI 2, sent twice, with a person watching the screen each time:

| Sent | Packet | `result` | What the human saw |
|---|---|---|---|
| `hdmi2` (`0x12`) | `51 84 03 60 00 12 CA` | `0x0`, both sends | the ASUS left DisplayPort and showed the MacBook |
| `displayport` (`0x0F`) | `51 84 03 60 00 0F D7` | `0x0`, both sends | the ASUS returned to the Mac Studio |

The `displayport` packet is byte-for-byte the string `displays.toml` already
documents for `ASUS -> DisplayPort`, which is worth more than the switch itself:
it shows the framing this route generates matches the allowlist exactly rather
than merely resembling it. **That is the finding that matters for any future
sidechannel work.** The hazard in aiming a packet at the LG's `0x50` was never
the values -- `0xD0`/`0xD1` are documented and this desk sends them daily from
two other platforms -- but a brand-new transport mangling a packet into a service
channel. Framing on this route is now measured, on a channel where a wrong
packet is harmless.

`result=0x0` is still not the evidence here; the person is. This panel family
returns success for writes it ignores, which is why the LG's stubbed `0x60`
looks identical to a working one on the wire.

**The LG accepts its service channel over this route, in both directions,
including while displaying the other machine.** `SetVCP 0xF4` on source `0x50`,
to the LG on its USB-C input, sent twice, each direction watched:

| Sent | Packet | `result` | What the human saw |
|---|---|---|---|
| `displayport` (`0xD0`) | `50 84 03 F4 00 D0 9D` | `0x0`, both sends | the LG left the MacBook and showed the PC |
| `usb-c` (`0xD1`) | `50 84 03 F4 00 D1 9C` | `0x0`, both sends | the LG came back to the MacBook |

Both packets are byte-for-byte the strings `displays.toml` documents. **The
second one is the whole finding**: it was sent while the LG was displaying the
PC, so the Intel route can command a panel that is showing another machine on
the manufacturer sidechannel. That is exactly what `pull` does, and with the
ASUS result above it means both of this desk's panels are reachable from an
Intel Mac by the same operations the Apple Silicon and Windows switchers use.

Only `0xD0` and `0xD1` were ever sent. The LG's documented `hdmi1` (`0x90`) and
`hdmi2` (`0x91`) remain unexercised and were deliberately kept out of the
instrument's allowlist: a service channel is not where a value is tried for the
first time.

**Enumerating proves nothing about whether a panel is there. Three separate ways
it lies:** with NOTHING attached, all five AMD framebuffers already advertised a
bus with transaction types `0x1F` (simple + DDCci + combined);
`IODisplayCreateInfoDictionary` returns a NON-NULL but empty dictionary for a
vacant framebuffer, so four empty ones were probed on every run; and the
built-in panel returned `IOI2CSendRequest=0x0` with `result=0x0` and a reply of
pure garbage (`E8 0C D0 15 ...`), because an internal eDP panel has no DDC/CI
responder. Only the `6E 88` framing distinguishes an answer from a non-answer.
The failures are at least distinct: `0xe00002d7` (`kIOReturnOffline`) from vacant
AMD framebuffers, `0xe00002c7` (`kIOReturnUnsupported`) from the Intel
framebuffer, whose bus advertises `0x13` -- no DDCci bit.

**The gMux moves a display between framebuffers under you.** With nothing
attached the built-in panel sat on `AppleIntelFramebuffer@0`; the moment an
external arrived it migrated to `AMDRadeonX6000...ATY,Boa@0` and the Intel
framebuffer held no display at all. So on Intel the framebuffer a panel lives on
is not stable across a hotplug -- the same hazard as the Windows index swap,
reached from a different direction, and the same answer: resolve by EDID.

**`display-probe` loses two fields on Intel, and the cause is the EDID lookup.**
It printed `1E6D|9E9E|GSM||<lg-edid-serial>|<uuid>|` for the format
`vendor|product|mfg|connector|serial|uuid|name`: **connector and name both
empty**, on both panels, on every reading. `collect_edids()` walks the registry
for a property literally named `EDID` and reads `Metadata`/`DFP Type
Description` beside it. On this Mac: **0** nodes carry `EDID`, **2** carry
`IODisplayEDID`, and there are **0** `IOPortTransportStateDisplayPort` nodes and
**0** `DFP Type Description` properties anywhere in the registry. Vendor,
product, serial and UUID survive because they come from CoreGraphics. The name
does not -- and `displays.toml` matches panels by `edid_name`. The same EDID that
`display-probe` could not find was decoded without trouble by `intel-ddc-probe`
through `IODisplayCreateInfoDictionary`, so the data is there; only the route to
it is Apple-Silicon-shaped.

**The suite runs on Intel; the install half cannot.** 10 of 11 files pass. All 26
failures are in `install.tests.sh`, and every one is the arch preflight refusing
first -- "this Mac is x86_64. m1ddc ... supports Apple Silicon only" -- including,
notably, the case that asserts the *m1ddc-missing* refusal, which the preflight
preempts. That refusal is correct; the consequence is that no install behaviour
is exercised on Intel at all. `shellcheck` was not installed on this machine and
its half was skipped. No `skip_case` skips anywhere. Separately, all three C
programs compile clean under `-Wall -Wextra` on x86_64, and `event-watch --list`
enumerated USB through IOKit and Bluetooth through `system_profiler` correctly:
**the detector is arch-neutral, and only the switcher is Apple-Silicon-bound.**

**What this settles, and what it does not.** It settles CAPABILITY: every
operation the two existing switchers perform has now been performed from an Intel
Mac -- both panels, both channels, both directions, each confirmed by a person
looking. It settles nothing about whether the transport should be BUILT, which is
a judgement about this desk rather than a reading, and is what decision 004 owes.

`tests/conventions.tests.sh` was extended in the same session and for this
reason. It asserts hard rule 5's gate is the only door, but it scanned `lib/` and
`trigger-kvm` -- **shell only** -- keying on the string `input-alt`, m1ddc's
spelling. C emitting the source byte numerically contains no such string, so the
scan would have counted one door and passed while a second existed. It now scans
the C as well. Its first version was itself wrong and only mutation caught it:
asserting the emitter's function contains `DDC_VENDOR_GSM` passed even with the
guard replaced by `if (0)`, because that name also appears in the refusal
message -- present but unreachable. It now asserts the comparison.

**Still not measured.** The USB-C-to-DisplayPort-direct reading the brief asked
for was not taken: it was the tie-breaker for an ambiguous result, nothing was
ambiguous once both DP Alt Mode and an HDMI protocol converter carried DDC, and
it is the only one of the cablings that would have cost the PC its LG
connection. The 13" 2019 model's Intel-GPU framebuffer path is untested -- it is
a different framebuffer driver, so none of this transfers to it. The LG's
`hdmi1`/`hdmi2` sidechannel values were never sent. And nothing here was run
without a logged-in session, so the Intel equivalent of the LaunchDaemon result
above is unknown.

## The dxva2 route on the onboard Intel GPU (Windows)

**2026-10-29, Windows -- the installed shipping path switches the ASUS both
ways at the local console.** The Windows publication-remediation candidate
was installed from `0be74f0+dirty`, product 0.2.0, specification revision 15,
on the reference Windows 11 / RTX 4090 desk (NVIDIA driver 616.64). The user
confirmed both displays initially showed Windows and moved the terminal to
the LG. The installed watcher was paused through its supported command with
UAC; its lock was released. A private copy of the saved configuration changed
only the ASUS transport to `dxva2`; all input values remained unchanged.

After an ASUS-only dry run resolved EDID `06B3:42E0`, the installed
`trigger-kvm.ps1 to mac -Only pg42uq -Config <private-copy>` sent standard
VCP `0x60 = 0x0F`. The user confirmed the ASUS showed the Mac and the LG still
showed Windows. `pull -Only pg42uq -Config <private-copy>` then sent
`0x60 = 0x11`; the user confirmed both monitors showed Windows. Neither return
code was treated as visual evidence. No VCP readback, service-channel command,
cable move or sleep test was used.

The installed walkthrough, driven through its typed fallback with an isolated
copy of that config, drew `From boot` disabled, named the ASUS, and refused
selection. Cancel preserved the real saved configuration. The original boot
watcher was restored enabled/running. This confirms the shipped dxva2 route
on this desk, not other adapters or Windows versions. The LG/NVAPI routes
were not physically re-tested during this check.

**2026-09-01, Intel probe measurements.** Taken on the Windows PC (i9-13900K / UHD 770, ROG STRIX Z790-A
GAMING WIFI BIOS 0805, RTX 4090), with `iGPU Multi-Monitor` newly enabled in
BIOS and **the ASUS PG42UQ's PC cable moved from the 4090 to the motherboard
HDMI output**. The LG stayed on the 4090 throughout, per hard rule 4. The
instrument is `C:\ProgramData\trigger-kvm\dxva2-intel-probe.ps1` -- not in the
repo, not installed, and not shipping code; it lifts the `SetVCPFeature` call
from the dxva2 implementation deleted at `70e5ed4`. It can send only VCP `0x60`,
only the values `0x0F` and `0x11` already documented for this panel, and only to
a monitor whose PnP interface path carries the EDID vendor+product it was told
to aim at. There is no I2C source byte anywhere in it, so it cannot reach `0x50`.

**The iGPU carries DDC, and dxva2 switches a standard panel over it -- both
directions, including from an inactive link.** With the ASUS on the motherboard
HDMI at 3840x2160 @ 60 Hz (the 4090 was driving it at 138 Hz; the cap is the
motherboard output and is expected, not a fault):

| write | link at the time | accepted | elapsed, both sends | panel moved |
|---|---|---|---|---|
| `SetVCPFeature(0x60, 0x0F)` -- to the Mac | active (showing the PC) | 1 + 1 | 127 ms | yes, confirmed visually |
| `SetVCPFeature(0x60, 0x11)` -- back to the PC | **inactive** (showing the Mac) | 1 + 1 | 140 ms | yes, confirmed visually |

The second row is the one that matters: `pull` always fires from an inactive
link, and this is where a transport that only works while it owns the panel
would have failed. It did not. Both writes were sent twice, as the bus is lossy;
both sends were accepted each time. Confirmation is the owner looking at the
panel -- the success codes are recorded above only because they were *also* true,
and they prove nothing on their own.

**The link stays fully enumerated while inactive.** Immediately after the ASUS
had switched away to the Mac, `EnumDisplayMonitors` still returned it with the
same `hMonitor` (`0x6008F`), the same `\\.\DISPLAY7`, the same interface path,
and `GetPhysicalMonitorsFromHMONITOR` still handed back one physical monitor.
The enumeration is indistinguishable from the active-link case.

**2026-09-01, Windows -- NVAPI cannot see a panel on another adapter, and the
switcher refuses it by name.** With the ASUS on the Intel output,
`nvapi-probe.ps1` reported `gpus=1` and `connected displays = 1` -- the LG alone
(`displayId=0x80061082 outputId=0x00000200 connector=DisplayPort edid=GSM(0x1E6D)
product=0x9E9D`). The ASUS was absent entirely, as expected: it is on a different
adapter. `trigger-kvm list` correspondingly showed one row, and
`trigger-kvm pull -WhatIf` refused with

```
REFUSING PG42UQ switch: no output identifies as it (EDID 0x06B3:0x42E0).
NVAPI enumerated: outputId=0x00000200 connector=DisplayPort edid=0x1E6D:0x9E9D serial=<lg-edid-serial>
```

which is the correct behaviour -- it declined rather than mis-aiming -- but it is
also the whole limitation: today an NVAPI-only Windows install covers only
panels on the NVIDIA card.

**2026-09-01, Windows -- session 0 gives dxva2 no usable handle, with the ASUS
on the Intel output.** From an S4U on-demand task (`tk-dxva2-s0`,
principal the owner's account, `LogonType S4U`, `RunLevel Limited`,
`LastTaskResult 0`; process-token elevation not recorded),
running as `sessionId=0 interactive=False`:

```
user32 EnumDisplayMonitors sees 1 monitor(s)
  monitor[0] hMonitor=0x10001 device='WinDisc' physicalCount=-1
             err=GetNumberOfPhysicalMonitorsFromHMONITOR failed, GetLastError=-1071241755
  monitor[0] interfacePath=''
matched 'AUS42E0': 0 monitor(s)
```

`-1071241755` is `0xC02625E5`, which Windows renders as *"The function failed
because the specified GDI device did not have any monitors associated with it"*.
So this is the 2026-08-30 phantom again, now characterised one level further: the
phantom is named `WinDisc`, it carries **no interface path at all** (so no EDID
identity), and it yields **no physical monitor handle** -- the failure is at
`GetNumberOfPhysicalMonitorsFromHMONITOR`, before any question of writing arises.
The moving of the ASUS to the Intel adapter changed none of this. Compare NVAPI,
which enumerates *and writes* from session 0 (above, 2026-08-30).

This is the reading that bounds the tier: **a dxva2 panel cannot be covered by
the boot tier.** It is a limitation to state, never a fallback to reach for --
an identity check that trusts `user32` in a non-interactive context does not
fail loudly, it silently mis-resolves onto the phantom.

**The gate is what stops that being dangerous, and it held.** In the session-0
run the probe matched 0 monitors and wrote nothing. Exercised directly against a
target that is not present (`-Target XXX0000`, interactive), it refused in the
same words: `need exactly ONE monitor whose interface path carries 'XXX0000',
found 0`. Matching on EDID vendor+product and refusing anything but exactly one
match is what makes an unidentifiable phantom a refusal rather than a mis-aimed
write.

**2026-09-01, Windows -- one EDID key does serve both transports, and the rest
of the PnP path does not.** Moving the ASUS between adapters changed its PnP
instance path from `DISPLAY\AUS42E0\5&<adapter-instance-a>&0&UID4352_0` to
`DISPLAY\AUS42E0\4&<adapter-instance-b>&0&UID49_0`, and its GDI name from `\\.\DISPLAY1` to
`\\.\DISPLAY7`. The `AUS42E0` component -- EDID vendor `AUS` (`0x06B3`) plus
product `0x42E0` -- was unchanged, as was the EDID serial `<asus-ascii-serial>`. Putting
the cable back on the 4090 restored the PnP path exactly, but **not** the GDI
name: the ASUS came back as `\\.\DISPLAY3`, a third value, having been
`\\.\DISPLAY1` before the move and `\\.\DISPLAY7` during it. Restoring the
original cabling did not restore the original index. For the
LG, all three sources agree: NVAPI reads `GSM(0x1E6D) product=0x9E9D`,
`WmiMonitorID` reports `GSM` / `9E9D`, and the dxva2 interface path carries
`GSM9E9D`. WMI's three-letter code is the 5-bit packing of the same EDID vendor
word the config already stores, exactly (`AUS` -> `0x06B3`, `GSM` -> `0x1E6D`).

So EDID vendor+product is a single identity key across NVAPI, WMI and dxva2, and
a per-panel transport choice needs no second key. **The full interface path is
not that key** -- the deleted dxva2 code matched on the whole string, which this
move would have broken. `displays.toml`'s standing warning holds here too: the
LG's product id is per-input, so this only means the key is *shape*-compatible,
never that a value may be copied between hosts.

Also recorded, since dxva2 descriptions came up: on the Intel output the ASUS
reports its real `szDescription` of `PG42UQ`, while the LG on the 4090 still
reports the generic `Generic PnP Monitor` -- the reason the deleted code did not
key on the description. The `hPhysicalMonitor` values themselves are ephemeral
(`0x0` on one call, `0x2` on the next, for both panels) and are not an identifier.

**Not measured.** Intel's own I2C API (IGCL) was not touched -- it is a third
transport and a separate decision. Nothing was sent to the LG over the Intel
route, and the LG's `0x50` service channel remains reachable only through
`NvDdc.WriteLgInput`. The ASUS's `hdmi2` value `0x12` was still never exercised.
No DisplayPort motherboard output was tried, only HDMI. And this says nothing
about a machine with **no** NVIDIA card at all: the LG's own switch still needs
NVAPI here, so this desk cannot be run from the iGPU alone.

## DDC reads

**2026-08-30, both platforms -- read-back values lie on both panels.** The
PG42UQ returned `0` for luminance, contrast, volume and `max luminance` on every
reading, whether or not it was the active input, while writes worked. The LG
returned real values on a settled active link and `-7` while the link was
inactive or renegotiating: it read `-7` immediately after a switch that had in
fact succeeded, then `100` seconds later. Recorded on the project's first day
(`ce4015f`), before this ledger existed; hard rule 2 rests on it. The
2026-09-01 Intel readings above add one nuance without changing the rule: the
ASUS's `0x60` input read tracked a real change while the `max` field beside it
was garbage, and the LG's `0x60` read `0x0F` whatever it displayed.

## The LG service channel

**2026-08-30, Windows -- what `0xF4` does to a PG42UQ.** With the old spraying
tool and the ASUS write isolated out (a `-Only lg` run, so the spray was the only
traffic on the wire), the ASUS ignored `SetVCP 0xF4`: no flicker, no setting
change. The only evidence anyone has on this, for that specific panel.

## Asking whether a watcher is running

**2026-09-06, macOS -- `pgrep` DOES see a boot-tier watcher from a user session,
so the Windows blindness does not reproduce here.** With the LaunchDaemon tier
installed and loaded (`launchctl print system/com.chrisrishel.trigger-kvm`
succeeds, the gui-domain agent is not loaded), `pgrep -f 'event-watch --exec'`
run from an ordinary Terminal returned **1**. The reason is the tier's defining
property: the daemon has `UserName` set and runs AS THE USER, so the watcher and
the caller share a uid and the process is plainly visible. There is no
session-boundary equivalent of `Win32_Process.CommandLine` coming back empty.

**Counting was still the wrong question, and `status` now asks the lock anyway**
(`specs/status.md` §2). Two reasons that survive the measurement above:

- The lock is what MAKES a second watcher impossible, so it is the authority on
  both halves of "is one running, and could there be two". A count can disagree
  with the thing that enforces the invariant; the lock cannot disagree with
  itself.
- Matching on a command line is brittle in the way this project has already been
  bitten by: the old filter carried `usb-watch --exec` beside `event-watch
  --exec` precisely because a pre-rename watcher ran unnoticed beside the real
  one for a day. A lock has no spelling to keep up to date.

Measured the same day, against the real binary: `event-watch --lock-status`
answers `running` while a watcher holds it and `none` when none does; **a lock
file whose mode is `000` reads as `running`**, which is the
`status.md` §2 rule that an existing-but-unopenable lock is a running watcher and
not an absent one. Asking creates no lock file on a machine that never ran a
watcher -- `O_CREAT` would leave a stray that the next reader could not
distinguish from a real one, and under the rule above an unopenable stray reads
as a watcher. The query needs no explicit `flock(LOCK_UN)`: `close()` drops it,
the same property that makes a killed watcher leave nothing to take over.

The Windows half of this question -- where counting genuinely could not see the
watcher -- is under "PowerShell console and language" below.

## Logs

**2026-08-31, macOS -- copy-truncate under launchd leaves no hole.** A throwaway
agent writing a line a second through `StandardErrorPath`, truncated mid-flight,
resumed at offset 0 with zero NUL bytes in the file.

## PowerShell console and language

**2026-10-30, Windows -- an unelevated administrator must still be offered
boot installation.** A new administrator-capable profile installed `2835cb0`
from a source archive, using profile and source paths that each contained a
space, apostrophe and Unicode. The fresh login-tier installation succeeded:
config and program were created in that user's profile, source hashes matched,
the installed shim reported 0.2.0/spec 15 and archive provenance, PATH contained
the intended `bin`, and one watcher ran as the intended Interactive/Limited
principal. The owner reported that From boot was disabled with the
administrator-account explanation. No UAC-decline/fallback observation can be
claimed from this run because the prompt was never reached.

Native Windows PowerShell 5.1.22621.7582 reproduced the eligibility failure
before production code changed: `whoami /groups /fo csv /nh` included the
Administrators SID as deny-only, `WindowsIdentity.Groups` omitted it, and the
actual `Test-CanElevate` returned false. The new native regression failed
`expected 'True', got 'False'`. This is token-query evidence, not a mocked
membership check. The same token's `WindowsIdentity.Claims` retained the
deny-only SID. Microsoft's [.NET reference source](https://github.com/microsoft/referencesource/blob/main/mscorlib/system/security/principal/windowsidentity.cs)
documents the filtering and claim generation.

Eligibility now accepts the exact Administrators SID only from enabled-group
or deny-only-group claims. It does not treat that as an elevated token or grant
access; installation still goes through UAC. Fixtures cover both group forms,
unrelated claim types/groups, empty claims, the already-elevated case and query
failure. The native test compares the actual function against `whoami`'s group
view. Replacing deny-only recognition with an unrelated claim type fails the
fixture.
Validation commands: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
windows/tests/run.ps1` passed all 18 files without skips, and the same invocation
of `windows/tests/mutate.ps1 publication` caught all 30 mutations. Product
version remains 0.2.0 and specification revision 15; this corrects the existing
boot-menu contract without changing shared behavior.

**Installed repeat at `4c0f13b`.** In the same disposable profile, the supported
source installer upgraded the login-tier installation with identical saved
config bytes. Through the installed shim from ordinary PowerShell, the owner
could select From boot and declined the UAC prompt. The command returned 0;
the resulting task was Interactive/Limited, owned by the intended user,
enabled/running, with the saved tier still login and original config bytes
unchanged. This is a declined-UAC fallback with existing configuration, not
a fresh-profile fallback observation.

The installed Save/Cancel check then passed: Cancel preserved bytes and Save
retained the synthetic unknown key; original config bytes were restored.
Selecting From boot again and approving UAC produced an S4U/Limited task for
that same user, with one owned watcher in session 0. Installed source hashes
matched `4c0f13b`, and the intended profile's files and PATH were verified.
Both source and profile paths contained spaces, an apostrophe and Unicode.
After a coordinated normal reboot, the owner signed into only the original
account, not either disposable account. The read-only native collector found
exactly one watcher for the test administrator in session 0, started at
21:40:43 UTC after the 21:40:14 UTC boot. Its task was enabled, S4U/Limited,
owned by the intended test user and had a boot trigger. This establishes
boot startup without that user's interactive logon on `4c0f13b`; it sends no
monitor writes and does not establish physical switching from session 0.
The installed shim then changed boot to login with exit 0. Before sign-out,
the intended Interactive/Limited task held logon/self-heal triggers and one
watcher in session 2. The owner signed out of the test account and signed back
in. The new session 3 held exactly one intended watcher created at 21:52:04 UTC,
before the helper was reopened, with the OS boot timestamp unchanged.
The installed login-to-no-autostart transition then produced an enabled
Interactive/Limited task with no triggers and one running watcher. After a
second real sign-out/sign-in, session 4 had no watcher process and the watcher
lock was free; the no-trigger task remained enabled. The standard-user profile,
fresh declined-UAC fallback and source-unavailable uninstall remain open.

The owner observed another UAC prompt for login-to-no-autostart. Read-only
Task Scheduler security inspection confirmed an Administrators-owned task;
the intended test user had mask `0x00120089` (read), while Administrators held
full access. The boot-to-login replacement had itself been registered by the
elevated installer, so the next replacement required elevation too. This is
the documented protected-task limitation, separate from the watcher's Limited
run level. No task ACL or owner was changed to bypass it.

**Real stopped-state cancellation at `4c0f13b`.** In elevated consoles in the
disposable administrator profile, the installed CMD shim ran `configure` and
the trigger check. The task was in the no-autostart tier, with no logon or
self-heal triggers. From enabled/stopped, the observer recorded enablement
changing true to false to true; the final watcher-lock check was stopped.
From disabled/stopped, the task stayed disabled and the final lock check was
stopped. Both configurations remained byte-identical, and neither helper
performed recovery or started a watcher. The owner confirmed pressing Ctrl+C
during both 90-second waits and answering Y to terminate the batch job.
Each case required three Ctrl+C presses before that prompt. State restoration
passed; single-press cancellation responsiveness is not established by these
observations. The earlier enabled/running case remains evidence on `2835cb0`.

**Installed uninstall and fresh fallback at `4c0f13b`.** The helper renamed
the disposable source directory, invoked the installed shim's uninstall and
restored the source name. Task and program were removed, config and log bytes
were retained, and PATH's entries matched the pre-install entries. The string
lost one trailing semicolon; no original PATH entry was removed. Uninstall
nevertheless returned 1, so this was not a clean success result.
After preserving the retained data directory, the owner completed setup with
no program, task or config present, chose boot and declined UAC. Exit 0, saved
login tier, intended Interactive/Limited task and one watcher were recorded.
This verifies fresh product-state fallback in the existing disposable profile;
it does not claim a second fresh operating-system profile.

**Windows installation fixes validated in fixtures.** A native test using the
actual generated CMD shim reproduced uninstall's false failure before the
production change: a harmless PowerShell child deleted that shim and exited 0,
but CMD returned 1 with `The batch file cannot be found`. The manage dispatch
now leaves its batch context before invoking PowerShell, with paths and
arguments already expanded. Native tests cover self-deletion with exit codes
0 and 7, and a calling batch file that must continue and receive either code.

The repeated UAC prompt on user-tier changes was also pinned by a regression
against `Invoke-Install`, with all task/files/PATH operations mocked. It failed
because the protected-task retry elevated the whole install. That retry now
elevates only removal of the old task; the normal parent verifies its absence
and registers the login/manual replacement. Tests cover both user tiers,
subsequent changes without another elevation, declined/failed removal, a child
claiming success while leaving the task present, and the removal helper's
strictly limited operations. These are Windows installation corrections;
the shared specification remains revision 15 and product version 0.2.0.
The corrected paths still require an installed, coordinated repeat before
their native release gates can be closed.

The full native Windows PowerShell 5.1 suite passed all 19 files without skips;
`windows/tests/mutate.ps1 publication` caught all 35 mutations. The separate
`install: the watcher under the task survives` mutation was also caught.
The initial full run exposed a structural-test false positive: it selected the
last `Get-ScheduledTask` condition, which was now a read-only removal check.
The test now identifies the block containing task unregistration from the AST,
with a self-test for the later read-only query. Its required `Stop-Watchers`
assertion is unchanged, and the original cleanup-removal mutation still fails.

Clean candidate `462204a` repeated the full Windows PowerShell 5.1 suite:
all 19 files passed without skips. CI run `41140109897` passed on both
platforms: macOS passed 13 files; hosted Windows passed 18 files, skipping
the NVIDIA-dependent resolve file and two driver cases explicitly. Its complete
Actions log was inspected and scanned privately. The clean source archive and
hash are prepared for the coordinated installed repeat; passing fixtures and
CI do not establish the corrected task permissions or uninstall on that profile.

**Installed task-permission repeat at `462204a`, 2026-10-30.** The disposable
administrator upgraded through the source installer in ordinary PowerShell;
configuration bytes and user PATH were unchanged, exit was 0, and installed
script hashes matched the candidate. The installed shim then changed login to
boot, boot to login, and login to no autostart. Native task security showed the
boot definition owned by Administrators; the login/manual replacements were
owned by the intended user, with that user's full-control ACE. Both user tiers
had Limited principals and exactly one visible, correctly owned watcher.
The final enabled manual task had no triggers, and its watcher held the lock.
The owner confirmed approving UAC for boot and its removal, then receiving no
UAC prompt for login to no autostart. The boot snapshot established S4U/Limited,
the intended principal and a held lock; its unelevated process enumeration did
not expose the session-0 process, so that snapshot alone does not count it.
The subsequent source-unavailable uninstall also passed. The helper paused
through the installed shim, renamed only the disposable source directory,
invoked installed `uninstall`, then restored the source name. Exit was 0;
task/program were absent and the watcher was stopped. Config/log bytes were
retained unchanged, the installed bin was removed from PATH, and all original
PATH entries remained. These checks close the two installed correction gates
for the administrator-capable profile; standard-user elevation remains separate.

**Standard-user boot eligibility, 2026-10-30.** Before any product installation
in the fresh standard-user profile, a harmless native Windows PowerShell 5.1
probe loaded the actual `462204a` eligibility functions. `Test-CanElevate`
returned false, although `EnableLUA = 1` and `ConsentPromptBehaviorUser = 3`.
The owner first declined the credential prompt (exit 1), then repeated it with
the disposable administrator credential. The second child exited 0 and recorded
an elevated token for that administrator. The standard user's PATH was unchanged;
the probe registered no task and changed no installation or policy. The approved
run's private receipt was preserved before the production change. This is native
credential capability evidence, not a standard-user installation pass.

The regression reproduced the false eligibility before the fix. The check now
recognizes standard-user credential prompts unless UAC is disabled or policy
explicitly denies them. Microsoft's [UAC policy table](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/user-account-control/settings-and-configuration/)
defines prompt values 1 and 3 and denial value 0. It reads policy only; Windows
still decides whether elevation succeeds. Unknown or unreadable policy keeps
the prompt available. The existing negative membership assertions remain,
with an explicit denied-prompt fixture; new cases cover permitted prompts,
disabled UAC, denial, unknown/missing values and read errors. The corrected
standard-user walkthrough and separate-credential install still need their
coordinated native repeat.

The full Windows PowerShell 5.1 suite passed all 19 files without skips;
`tests/mutate.ps1 publication` caught all 38 mutations. The three new mutations
hide permitted credential prompts, ignore explicit denial, and ignore disabled
UAC; each was caught. An earlier mutation run stopped when the unchanged
harness's `Move-Item -Force` could not restore `host.ps1`. The preserved backup
differed only by that temporary mutation; it was copied back and verified by
hash before repeating the unchanged harness. The restoration failure's cause
was not established. No assertions were weakened and no mutant remained.

The watcher, switcher, configuration library and monitor/trigger-check code
remain identical to `2835cb0`; these installer eligibility corrections do not
alter the paths covered by the dated visual observations. Those observations
remain tied to their recorded candidate and environment; no new physical
switching is claimed by the installation checks.

**Fresh standard-user install at `ed1a0c0`, 2026-10-30.** From boot was
selectable; the owner approved UAC using the separate disposable administrator.
Config and program files were created in the standard user's profile and
installed script hashes matched the candidate. `Register-ScheduledTask`
reported access denied (0x80070005); no task or watcher existed afterwards,
and overall exit was 1. The intervening "registered and started" and installed
autostart messages were false. The failed state and saved config/stamp snapshots
were preserved privately; it is not an installation pass.

A native PowerShell module fixture reproduced the error-handling gap before
the production change. Its task commands emit nonterminating errors under
their module scope, so the caller's preference alone did not invoke the catch.
The actual installer returned 0 after a failed registration. Registration,
enablement and start now request terminating errors explicitly and report only
the state reached. Manual installs also check the watcher lock before claiming
success. The full Windows PowerShell 5.1 run passed all 19 test files without
skips, including parsing/conventions; all 42 publication mutations were caught,
including the four new task-operation/manual-start mutations. Commands were
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/tests/run.ps1`
and `powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/tests/mutate.ps1 publication`.
Existing assertions remain. This is fixture/native-suite validation, not a
successful repeat of the standard-user installation.

Microsoft's [task security documentation](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks)
requires a password for an administrator to register S4U for a different user.
This is a candidate explanation, not an established complete cause. The native
bounded diagnostic also denied the standard user's own S4U registration without
triggers (0x80070005), as well as administrator-to-standard-user registration.
The administrator's own S4U control registered and ran in session 0. Because
the seed could not be created, adding a boot trigger to it was **not tested**.
All fixture tasks were removed; no product task or monitor input was changed.
The follow-up verified the registered control as S4U / Limited, compatibility
Win7, yet its session-0 process had `TokenElevation=1`,
`TokenElevationType=1` (no linked token), and enabled Administrator membership.
The elevated registration helper had type 2; an ordinary interactive owner
process had elevation 0/type 3. These read-only `GetTokenInformation` checks
used the process token, not an inferred task setting. The control used the
same principal/settings construction as the installer; the actual installed
watcher was paused and was not measured by this diagnostic.
Read-only LSA queries found no direct rights for the disposable standard user,
and no batch-logon right in Users or its other queried well-known groups;
Administrators did have `SeBatchLogonRight`. No rights were changed by this
diagnostic. The owner confirmed completion with zero remaining fixture tasks.
Both standard-user registration and actual boot-token restriction require
the further native validation below before the installed boot gate can pass.

The error-reporting correction landed as `b6936eb`. Its clean checkout passed
all 19 native test files without skips. CI run `41147087456` passed both
platforms: Windows 18 files, with the NVIDIA resolution file and two driver
cases explicitly skipped; macOS 13 files. Full logs were inspected. The privacy
refresh covered 235 commits / 1,253 text blobs and all 23 available Actions
logs, with no new findings or authorship changes; secret scanning remained
unavailable. The owner's separate privacy-review block remains in force.

**2026-10-30, Windows -- authenticated S4U registration and token restriction.**
The disposable standard account's bounded own-user and different-administrator
registration attempts still failed after temporarily adding only
`SeBatchLogonRight`. The original rights were restored and no fixture tasks
remained. A subsequent console in the original account used a password entered
locally for the disposable standard account; it was passed only in memory to
COM `RegisterTaskDefinition` with logon type 2 (S4U). Registration succeeded,
retaining S4U/Limited and the intended owner. It did not add the batch-logon
right. Without that right no action receipt appeared; after a temporary grant,
the identity-only action completed in session 0 with the intended standard
owner, medium integrity, no administrator membership and no writable handle to
`HKLM\SYSTEM`. Cleanup restored the prior rights and removed both fixture tasks.
No product installation or display input changed.

The administrator S4U control had high integrity, enabled administrator
membership and administrative privileges despite Limited. SAFER NORMALUSER
removed administrator membership and all privileges except change-notify,
but retained high integrity. Explicitly setting medium integrity produced the
intended effective restrictions and refused the writable registry handle.
`TokenElevation` remained 1/type 1: these tests establish effective rights,
not a split UAC token or a cleared elevation flag. The ordinary interactive
owner could also launch a bounded child through this restricted-token path.

The Windows host now embeds its bootstrap in the protected task definition;
it checks owner, session, memberships, integrity and retained privileges before
loading any installed watcher code. Cross-user boot registration uses a local,
non-persisting credential dialog and S4U authentication, with a narrowly scoped
batch-logon grant and rollback on registration failure. The installed workflow,
credential dialog and restricted session-0 device access remain release gates.
The native Windows PowerShell 5.1 suite passed all 21 files without skips,
including parsing/conventions, actual encoded-bootstrap children and bounded
cleanup through both launch chains. All 53 publication mutations were caught.
The cross-user installer regression first failed because the actual old flow
omitted the password request and authenticated registration; it now also checks
Cancel before task/file changes and secret disposal on success/failure. Native
COM definition tests retain startup, self-heal, battery and restart settings;
fixture registration tests check authentication and selective rights rollback.
These results are automated/native OS evidence, not an installed workflow or
physical switching result. Commands were `powershell.exe -NoProfile
-ExecutionPolicy Bypass -File windows/tests/run.ps1` and the same invocation of
`windows/tests/mutate.ps1 publication`.
The fix landed as `473274d`. Its clean checkout also passed all 21 native files
without skips. CI `41153314261` passed both platforms: Windows 20 files, with
`resolve.tests.ps1` and two NVIDIA-driver cases explicitly skipped; macOS 13
files. Full logs were inspected. No installed copy was upgraded by these tests.
Microsoft documents [S4U authentication and batch-logon requirements](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks),
[S4U registration without stored passwords](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskfolder-registertaskdefinition),
[SAFER token computation](https://learn.microsoft.com/en-us/windows/win32/api/winsafer/nf-winsafer-safercomputetokenfromlevel)
and [mandatory integrity control](https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control).

**2026-10-30, Windows -- boot bootstrap failure handling.** A native bounded
fault-injection fixture made token restriction fail before any watcher started.
The bootstrap returned failure but wrote its user-supplied log path while still
holding the original token. The regression reproduced that file write before
the correction. The handler now reports the failure to stderr and exits 1;
it does not write to user-controlled paths. Early bootstrap failures are
diagnosed through Task Scheduler's Last Run Result. The regression asserts
failure, no child receipt and no log file. All 12 affected boot mutations were
caught, including reintroducing this write. The full native PowerShell 5.1 suite
passed all 21 files without skips again; the preceding full publication run
caught all 53 mutations before the new case was added. No installed task,
account right or monitor was changed by this test.
The correction landed as `6a5afcf`. Its clean checkout passed all 21 native test
files without skips. CI `41154488503` passed macOS 13 files and Windows 20 files;
the NVIDIA resolution file and two driver cases were explicitly skipped on
the hosted Windows runner. Full logs were inspected.

**2026-10-30, Windows -- shipped bootstrap in session 0.** After the owner's
UAC approval, two uniquely named S4U/Limited fixture tasks exercised the exact
bootstrap from clean `6a5afcf`. Each was limited to 30 seconds and launched only
an identity-reporting child. The normal case preserved the intended owner and
session 0, ran at medium integrity (8192), had neither administrator nor
power-user membership, retained only `SeChangeNotifyPrivilege`, and forwarded
the child's expected exit 7. A source mutation omitting the integrity-setting
call failed with exit 1 before producing a child receipt or user log. Both
tasks were removed; independent enumeration confirmed zero remaining fixture
tasks. Original owner config/PATH were unchanged and the product task remained
absent for the profile matrix. Receipts completed at 2026-10-31 01:34 UTC.
This is native session-0 token/launch evidence, not an installed watcher,
startup-after-reboot, device-access or physical-switching result.

**2026-10-30, Windows -- installed standard-profile workflow on `6a5afcf`.**
Windows 11 build 22631, native Windows PowerShell 5.1, with spaces, an
apostrophe and Unicode in the actual profile and source paths. The retained
archive manifest/hash and every installed source hash identify `6a5afcf`; the
installed 0.2.0/specification-15 stamp correctly says it is not a Git checkout.
The owner supplied a console transcript and the helper saved before/after
receipts privately. Review of those receipts passed 46 explicit assertions.

After approving separate-administrator UAC, cancelling the intended standard
user's password dialog preserved every program hash, config hash and PATH,
with no task or watcher created. Retrying with that user's password succeeded:
S4U/Limited, the intended principal, one watcher holding its lock, session 0,
medium integrity (8192), no administrator/power-user membership and only
`SeChangeNotifyPrivilege`. Config bytes and PATH were preserved. The program
directory was owned by Administrators; the config was owned by the intended
standard user. That user subsequently configured and uninstalled the program
successfully through its installed shim.

A real reboot occurred at 2026-10-31 02:38:26.5 UTC. The one intended watcher
started at 02:39:05.552 UTC, about 39 seconds after boot and 174 seconds before
the first interactive logon at 02:41:59.585 UTC. Its actual token again passed
the same rights checks. This establishes installed pre-login startup, not a
physical switch. Boot-to-login produced a user-owned Interactive task. Installed
Save retained a synthetic unknown key; Cancel preserved config bytes and the
helper restored the original config afterward. Real sign-out/sign-in produced
one new watcher in the new interactive session. Changing to no autostart started
one watcher immediately, then a further sign-out/sign-in left the enabled task
without triggers or a watcher.

Both source-unavailable uninstalls removed task/program/watcher and the product
PATH entry while retaining exact config/log bytes. The original PATH entries
and ordering survived; an original trailing semicolon was normalized away by
the existing PATH helpers. A private byte-identical-PATH assertion failed on
that one-character difference, which was investigated and retained as an
explicit limitation rather than reported as byte preservation. No repository
test assertion was changed. Between uninstalls, a fresh product-state setup
(no program/config/task, retained data backed up separately) accepted actual
UAC decline and installed a working login fallback. This is fresh product
state in the existing disposable profile, distinct from its earlier first
profile installation. No monitor or trigger checks were run in this session.

**Original-owner restoration, 2026-10-30.** The coordinated supported installer
upgraded the original owner from `2835cb0` to clean `6a5afcf`. Installed source
hashes/stamp, unchanged original config bytes/PATH, boot/S4U enabled state and
exactly one intended watcher were verified. Its actual token passed the same
session-0/ordinary-rights checks. The temporary Switch user policy was restored
to its original DWORD 1. No fixture tasks remain. Read-only account-right
comparison found only the standard user's expected added batch-logon right,
retained after successful uninstall by design. The separate administrator-PATH
check remains unverified: its profile hive was unloaded and Windows rejected
the private copied-hive read. This does not establish corruption of the live
profile. The restored owner's real reboot, restricted session-0 device access
and visually confirmed switching remain outstanding. Account/profile deletion
has not been performed.

After the profile session, native
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/tests/run.ps1`
passed all 21 files without skips, including parsing/conventions. No production
code changed during this evidence review. Earlier mutation results retain
their stated candidate scope. CI `41157257426` at `d4152aa` passed both platforms:
macOS 13 files plus shellcheck; hosted Windows 20 files, with its NVIDIA
resolution file and two driver cases explicitly skipped.

**2026-10-30, Windows -- restored owner's final reboot.** Installed `6a5afcf`
retained its exact source identity, config bytes and owner PATH. The boot at
2026-10-31 03:30:04.5 UTC produced one intended session-0 watcher at
03:30:43.767 UTC, about 39 seconds after boot and 22 seconds before the first
interactive logon at 03:31:06.066 UTC. Actual process-token inspection confirmed
medium integrity, no administrator/power-user membership and only
`SeChangeNotifyPrivilege`. The enabled S4U task, boot trigger and held watcher
lock were verified. A separate read-only NVAPI enumeration on driver 616.64
matched the earlier display/output identity fields and local EDID product keys
for both panels. Neither the reboot evidence nor enumeration sent display
writes or established physical switching.

**2026-10-30, Windows -- restricted session-0 NVAPI switching on `6a5afcf`.**
After the restored owner's reboot and local sign-in, bounded 30-second native
tasks used the exact installed `Get-BootTaskArguments` bootstrap and installed
switcher. An identity-checking wrapper verified the intended owner, session 0,
medium integrity, no administrator/power-user membership and only change-notify
privilege before invoking the switcher. Four one-panel `-WhatIf` cases passed;
the four actual commands (`to mac` and `pull` for each panel) also returned 0.
The saved map and source hashes were checked before invocation. Only saved,
allowlisted input values were used, through the shipping transport's EDID gate;
there was no service-channel probing or VCP readback.

The owner explicitly confirmed ASUS to Mac and back while LG stayed on Windows,
then moved the console/chat to ASUS and confirmed LG to Mac and back while ASUS
stayed on Windows. Both displays ended on Windows. These are physical
observations under the restricted session-0 token after local sign-in, not a
detector-triggered or pre-login physical-write test. Earlier ASUS dxva2 and
local-console NVAPI observations remain separate; `trigger-kvm.ps1` and
`config.ps1` are byte-identical between `2835cb0` and `6a5afcf`.

The private console restored the watcher and removed its tasks, then failed
while serializing `List[object]` with an array subexpression under PowerShell
5.1. All eight individual command/token receipts survived. The owner supplied
a separate explicit chat confirmation of the four visual transitions and
working-display sequence; original per-prompt timestamps and the host-task
exit-code summary were not retained. The collector failure was reproduced
without hardware, fixed with `ToArray()` and immediate confirmation persistence,
and the original conversion mutation was caught. No display write was repeated
to recover the record. Independent checks verified zero fixture tasks and the
original owner's single restricted watcher, enabled/running boot task and
unchanged config/PATH/source identity.

**Administrator PATH comparison, 2026-10-30.** Windows' application/live-hive
load APIs rejected private copies of the unloaded disposable administrator's
profile hive; no temporary registry mounts remained and the original hive was
not changed. The final read used the existing System32 `offreg.dll`, with only
[`OROpenHive`](https://learn.microsoft.com/en-us/windows/win32/devnotes/oropenhive),
`ORGetValue` and `ORCloseHive` imported. A clean, checksum-valid committed copy
was read in memory; its file hash remained unchanged. Its PATH exactly matched
the administrator's post-uninstall baseline from before the standard-user
elevation session. The intended standard-user install did not change the
administrator's PATH. No account switch or further elevation was needed for
this final comparison; no third-party reader or product dependency was added.

**2026-10-30, Windows -- approved disposable-profile cleanup.** Both recorded
account SIDs and exact profile paths matched the creation/baseline records;
the profiles were unloaded and no tasks referenced them. Both profiles were
backed up privately before either was deleted. SHA-256 comparisons verified
9,390 administrator-profile files and 9,833 standard-profile files. Each
profile's 70 links were preserved as raw reparse metadata without traversing
their targets. The first ordinary-copy attempt refused app-execution aliases
and stopped before deletion; the corrected backup helper passed a native
fixture proving file preservation and no junction traversal. No backup failure
was ignored.

The standard account's added batch-logon grant was restored to its recorded
baseline before native profile/account deletion. Independent checks confirmed
both accounts, profile registrations and profile directories absent; both
verified backups retained; no related fixture tasks; and the original owner's
single restricted watcher, enabled boot task, exact installed `6a5afcf` source,
config/PATH and original Switch user policy intact. Private backups and raw
validation receipts remain available. No original-owner files were removed.

CI at `4c0f13b` passed both platforms on the second attempt. The first Windows
attempt failed before the unchanged native-cleanup fixture's child produced a
report; the cause was not established. All 13 native invocation forms and the
generated launch chain passed locally, and the failed CI job passed on an
unchanged rerun. No assertion or timeout was changed. Hosted Windows passed
17 files, with one NVIDIA-dependent file and two driver cases explicitly
skipped; macOS passed 13 files.

**2026-10-30, Windows -- native fixture report publication.** The post-reboot
full suite failed in `native-cleanup.tests.ps1` after its first invocation case:
the parent saw `received.json` while the child still held it open for writing,
and `Get-Content` raised an `IOException`. A bounded native child holding that
file open reproduced the failure in the unchanged `Wait-FixtureReport`.
This identifies the local failure; it does not establish the cause of the
earlier CI report-timeout failure.

Fixture children write complete JSON to a sibling temporary file, close it,
then move it to the final report name. A native self-test holds publication
behind an explicit gate and asserts the final report is absent, then releases
it and checks the complete JSON. Publishing to the final name prematurely is
a mutation. The existing 13 execution-boundary cases, quoted generated
launcher/watcher checks, owner/path assertions and 10-second report bound are
retained. Only the test protocol changes; installed product files are unchanged.
The full `windows/tests/mutate.ps1 publication` run caught all 31 mutations,
including the new publication-boundary assertion. The subsequent Windows
PowerShell 5.1 `windows/tests/run.ps1` run passed all 18 files, including parsing
and conventions. One dxva2 dry-run case explicitly skipped because that session
enumerated no physical panel during the account-switching matrix; that case
is not a pass. Once the owner returned to the original local console,
`windows/tests/run.ps1 resolve -Verbose` passed without skips, including that
dxva2 dry run. Neither invocation sent physical monitor writes.
CI for `21987c3` passed on both platforms: hosted Windows passed 17 files,
explicitly skipping the NVIDIA-dependent file and two driver cases; macOS
passed 13 files. Its Actions log was retrieved and scanned privately.

**2026-10-30, Windows -- reviewed candidate `2835cb0` installed and its Save/
Cancel workflow checked.** Environment: Windows 11 Education build 22631,
Windows PowerShell 5.1.22621.7582, NVIDIA RTX 4090 driver 616.64 and Intel UHD
770 driver 32.0.101.7088. Before the coordinated change, the installed stamp
was `41218f5+dirty`; the task was S4U, Limited, owned by the intended user,
enabled/running, with the watcher lock held. Private access-restricted backups
preserved the program, data, task XML and user PATH. The primary checkout's
pre-existing work was preserved; installation used a clean isolated checkout.

Through the installed shim, `trigger-kvm pause` released the lock. Running the
clean candidate's `windows/install.ps1` through Windows PowerShell with
`-NoProfile -ExecutionPolicy Bypass -File` completed successfully. The installed
stamp is **`2835cb0` / 0.2.0 / spec 15**, and installed script hashes match that
candidate. All 17 saved keys and user PATH were preserved. Elevated CIM ownership
inspection found exactly one installed watcher, the lock was held, and the
original S4U/Limited/enabled/running state was restored.

The installed `trigger-kvm configure` typed-input flow was exercised twice:
`q` then Enter returned 1 and left config bytes unchanged; selecting Save after
adding `release.fixture = keep` returned 0, retained that unknown key and every
original value, and preserved the installed stamp. Original config bytes were
then restored and `trigger-kvm restart` restored the owner watcher. These are
native installed-product/Task Scheduler checks, not mocked OS results. Fresh
profiles and separate-account elevation require the matrix below.
The full Windows PowerShell 5.1 suite also passed all 18 files without skips.
An additional spec-only invocation inside the restricted execution sandbox
returned an 8.3-path alias mismatch; the unchanged test passed when rerun in the
native user context. No assertion was changed to obtain that pass.

**Interactive cancellation, same candidate and environment.** Through the
installed CMD shim, the owner selected Test the triggers and pressed real
Ctrl+C during the 90-second wait, without moving the USB switch. The owner
confirmed the keystroke; the console recorded the interrupted pipeline and CMD's
termination prompt. An independent observer saw enabled/running become
disabled/stopped at 20:42:12.947 UTC and enabled/running with exactly one watcher
again at 20:42:17.500 UTC. The previously recorded next scheduled run was
20:42:42 UTC, so the observed restart preceded scheduler self-heal. The final
lock check passed and the helper's recovery path was not used. This is native
interactive cancellation evidence for the enabled/running starting state;
enabled/stopped and disabled/stopped Ctrl+C cases remain untested interactively.
Timeout restoration has native coverage for all three states; error paths have
fixture coverage.

**Physical NVAPI switching, same candidate and environment.** The installed
watcher was paused through `trigger-kvm pause`. From the installed directory,
Windows PowerShell 5.1 ran `trigger-kvm.ps1 to mac -Only pg42uq`, then
`trigger-kvm.ps1 pull -Only pg42uq`, using the original saved configuration.
The terminal stayed on the LG. The owner visually confirmed the ASUS showed
the Mac and then Windows, while the LG remained on Windows. After the owner
moved the terminal to the ASUS, the same two commands with `-Only lg` moved
the LG to the Mac and back; the owner confirmed both changes and that the ASUS
remained on Windows. All commands returned 0; the visual confirmations, not
those exit codes, establish physical switching.

The saved ASUS standard-DDC values were `0x0F` (Mac) and `0x11` (Windows);
the LG's gated manufacturer path used `0xD1` and `0xD0`, respectively. No VCP
readback, service-channel probing or S3 test occurred. The UAC prompt in this
session was for pausing the protected boot task; the manual switch commands
did not request elevation. This proves local-console NVAPI switching on the
reference desk, not a fresh boot/session-0 write. The 2026-10-29 ASUS dxva2
observation is separate evidence on the earlier candidate; that transport is
unchanged. The watcher remains deliberately paused during the coordinated
disposable-profile matrix, whose restoration step must restore the owner's
boot/enabled/running state.

**2026-10-30, Windows -- cleanup must recognize the execution boundary, not
search for a later `-File`.** At `4a4ba59`, the actual `Stop-Watchers` function
under Windows PowerShell 5.1.22621.7582 selected an unrelated synthetic process
for each of `/Command`, `-co` and an implicit script command. CIM, ownership and
termination were mocked for this pre-fix reproduction; no real process was
stopped. Adding regression cases before changing production code also exposed
false selections for other command spellings and malformed token boundaries.

[Microsoft's Windows PowerShell command-line reference](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1)
defines the remainder after `-Command` as command text and after `-File` as the
script and its arguments. Native bounded children confirmed that `inspect.ps1`
received the synthetic watcher path as its own `-File` argument for `-Command`,
`/Command`, `-c`, `/c`, `-co`, `/co`, `-comm`, an implicit command and an explicit
`-File inspect.ps1` invocation. Four encoded-command forms (`-EncodedCommand`,
`/EncodedCommand`, `-ec`, `-enc`) executed the same payload. These are native
host-parsing observations, separate from mocked command-line selection tests;
the latter also include uncertain/invalid forms that cleanup must refuse.

Cleanup recognizes only the installer's optional, ordered host flags followed
by `-File` and a complete script-path token. It retains exact installation-path
and owner checks. The native regression fences CIM enumeration to fixture PIDs,
uses real ownership/termination APIs, and leaves all 13 unrelated children alive.
The generated WSH launcher and harmless watcher child both stop, with paths
containing spaces, an apostrophe and Unicode. Each child sleeps at most 20
seconds and has no watcher lock, event source or monitor code.

Validation: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
windows/tests/run.ps1` passes all 18 files without skips, including parsing and
conventions. `windows/tests/mutate.ps1 publication`, invoked with the same host
flags, catches all 29 mutations. Replacing the narrow host-prefix grammar with
an arbitrary scan fails the command-boundary assertion; path and owner removal
mutations also fail. The live installed watcher, task and displays were not
changed. Installation/account/autostart checks and final physical NVAPI switching
remain in `windows/RELEASE-CHECKS.md`; privacy review remains open in `TODO.md`.

**2026-10-30, Windows -- CI temp paths exposed DOS-alias assumptions in two
new fixtures.** The first remediation push (`41218f5`) passed macOS CI but
failed Windows' native-publication and conformance-source fixtures. Reproduced
locally: enumerating a source tree through its 8.3 alias or a trailing dot
segment returned three scripts instead of two because the tests-directory
exclusion compared an unexpanded prefix. With TEMP/TMP set to the short alias,
the elevation transcript path was expanded to the long name, so the fixture's
prefix assertion rejected the same directory. Normalizing with `Get-Item`
before comparison fixes both. The suite retains its exact two-source and
apostrophe/Unicode assertions, explicitly exercises aliases, and mutates away
source-root normalization to prove the exclusion fails again.
The corrected candidate passes all 17 native test files without skips and all
28 publication mutations are caught.

**2026-10-29, Windows -- publication remediation on Windows PowerShell
5.1.22621.7582.** The native suite passes all 17 files without skipped cases;
`tests/mutate.ps1 publication` catches all 27 mutations, and
`tests/mutate.ps1 'trigger check'` catches all five existing cleanup mutations. These are
three distinct kinds of evidence:

| Layer | Observed result | Limit |
|---|---|---|
| Native PowerShell with fixtures | Declined/incomplete monitor rounds cannot pass; repaired maps invalidate earlier confirmations; Escape restores computer/removal/monitor state; cleanup rejects unrelated paths and owners; trigger cleanup restores enabled/running combinations on timeout, error and cancellation; fractional settle requests 250/750/1125 ms | UI answers, writes and most OS effects are stubbed; this does not prove a physical switch |
| Native Windows APIs | WSH executes UTF-16 launchers and CMD forwards through apostrophe/Unicode paths; the exact elevation wrapper propagates child exit 7 and its transcript; CIM ownership/path cleanup stops a bounded harmless process; both NVAPI bindings load the system DLL and reject a working-directory fixture under a simulated missing-library name | The child-path fixture is unelevated; it does not validate a separate standard user's UAC credentials |
| Native console host | 20 cases at widths 24, 60, 80 and 120, around one- and two-row boundaries; dirty buffer cells and shrinking frames leave no folded, final-column or tail residue | Hidden Windows consoles; other terminal hosts remain outside this measurement |

The original publication defects were reproducible under Windows PowerShell
5.1 with isolated function/OS fixtures; they were not dismissed as PowerShell 7
differences. The conformance coverage report identified a latent gap rather
than an already omitted production file: a nested source fixture now proves
recursive coverage, and comment-only wording is rejected in PowerShell and
embedded C#. Test roots include the process id and the convention checker
rejects a shared TEMP root. An empty saved trigger list retains the saved-state
label and restart reminder: it cannot prove that an already running watcher
has no older entries (`specs/status.md` 4.1).

**Coordinated installation check, same date.** Before upgrading, the program,
config and task definition were backed up privately. The existing boot task's
principal resolved to the current user's SID, S4U, RunLevel Limited. Unelevated
`pause` correctly refused to claim success; elevated `pause` released the lock.
The source installer completed through its UAC relaunch with exit 0. Config keys
and user PATH were unchanged; the new stamp reported 0.2.0 / spec 15 /
`0be74f0+dirty`, and the watcher held its single-instance lock. Installed-shim
`status` reported the saved-state label and restart reminder. Installed-shim
`configure` with `q` then Enter cancelled with exit 1 and no config change.

The installed trigger check also ran against the **real boot task** in three
states: disabled/stopped, enabled/stopped, and enabled/running. Each used the
real one-shot with synthetic absent `usb:ffff:ffff`, a two-second timeout and
no `-Pull`. Each restored its prior enabled/running state; the original
enabled/running state was restored at the end. Error and Ctrl+C restoration
remain fixture coverage, not an observed interactive cancellation. Fresh
profiles, standard-user elevation, UAC decline, tier transitions, logon/reboot
and uninstall remain the coordinated checks in `windows/RELEASE-CHECKS.md`.

**2026-09-08, Windows -- a `switch` statement takes over `$SWITCH`, in the scope
that runs it and in every function called from it.** `$switch` is an automatic
variable holding the running switch's enumerator; PowerShell variable names are
case-insensitive, so a script-scope `$SWITCH = 'C:\dest\trigger-kvm.ps1'` reads
back as the empty string from inside `switch (1) { default { ... } }` and from
inside a function that switch calls, then returns to its own value when the
statement ends. `Get-Variable -Name SWITCH -ValueOnly` there answers an
`SZArrayEnumerator`, and `$enumerator -ne 'x'` FILTERS rather than compares:
it returns the empty collection, which is falsy, so a check written the obvious
way reports that nothing is wrong. Compare as text.

Live consequence, found by running the installer: `install.ps1`'s verb dispatch
is `$code = switch ($Command) { ... }`, and `$SWITCH` was the installed
switcher's path. `Copy-Item <source> ''` resolves the destination against the
current directory, so an install run from the source tree threw `Cannot
overwrite the item C:\...\windows\trigger-kvm.ps1 with itself` partway through,
after the log had said it was installing. `uninstall` could not remove a file
whose path was blank, and a task registered on that path would have carried an
empty `-Exec`. `$foreach` and `$_` have the same shape; `$ErrorActionPreference`
and the other preference variables do not, because nothing shadows them
mid-statement.

**2026-09-08, Windows -- `& '<script>' <args> *> '<file>'` captures neither the
failure nor the exit code.** A terminating error propagates OUT of the redirected
command and is reported after the redirection has ended, so the file holds only
what was printed before it. Measured against a script that prints one line and
then throws: the file has the line and not the error, and the host exits 1. The
same shape flattens success too -- a script ending `exit 7` also came back as 1.

Wrapping the call so the catch is inside the redirection fixes both:
`& { try { & '<script>' <args>; $global:tkRc = $LASTEXITCODE } catch { $_ |
Out-String | Write-Output; $global:tkRc = 1 } } *> '<file>'; exit $global:tkRc`
-- the thrower's error is now in the file, and the clean script comes back 7.

This is load-bearing because `-Verb RunAs` cannot be combined with
`-RedirectStandardOutput`, so the transcript is the only way to see what an
elevated child said, and its window is hidden. Live: an install failed in the
elevated child and the parent printed a transcript containing one line and the
words "what it reported is above".

**2026-09-08, Windows -- variable names are case-insensitive, so `$LIBDIR` and
`$libDir` are one variable.** `install.ps1` bound the first to the installed
`lib\` and the second, sixty lines later, to the SOURCE `lib\` -- at load time,
before any verb. Every install then created the source directory instead of the
destination one, copied `lib\*.ps1` from the source onto the source, and threw
`Cannot overwrite the item ... with itself` with `config.ps1`, `event-watch.ps1`
and `trigger-kvm.ps1` already copied and `install.ps1` not. Diagnosed from the
mtimes inside the installed directory, which `Copy-Item` preserves from the
source: the three copied files carried that day's source timestamps and the
files after them in the function did not.

**2026-09-02, Windows -- an unelevated caller reads `Win32_Process.CommandLine`
as EMPTY across the session boundary, so counting processes cannot see a
session-0 watcher.** From an interactive session-3 shell: **183 of 183 session-0
processes returned a blank `CommandLine`**, against 98 of 130 populated in the
caller's own session. Nothing is thrown and no error is set -- the property is
simply empty, so a `Where-Object { $_.CommandLine -match ... }` filter drops the
process silently.

The consequence was live: `trigger-kvm status` printed `watchers : 0  <- expected
exactly 1` while the boot-tier watcher (pid 14008) was running and had fired
`pull` 40 minutes earlier. `restart` shared the filter and would have reported
"no watcher came up" about one that had. **A false alarm pointing at the healthy
steady state**, which invites someone to fix a system that works.

**The lock answers what the process table cannot.** `OpenExisting` on the
watcher's named mutex distinguishes four states from any session, unelevated, and
the one that matters is `UnauthorizedAccessException`: the name EXISTS under a
token the caller cannot open, which is exactly what a session-0 watcher looks
like from a desktop session -- a POSITIVE result, not a failure.
`WaitHandleCannotBeOpenedException` is the genuine "nothing ever created it".
Since the mutex is also what makes a second watcher impossible, the answer is a
state rather than a tally that can disagree with itself.

Measured the same day: **a mutex created with a DENY ace for the caller
reproduces the access-denied case in-process**, so the branch is testable without
a second logon session. The creating handle keeps working, because the access
check happened when it was created.

**2026-09-02, Windows -- an install did not replace the running watcher, and said
nothing.** Read out of the log rather than staged: every time a watcher arms it
writes `watching N device(s)` and a `context:` line, and the whole log carries
just three arms -- `2026-08-30 20:52:05`, `2026-08-30 20:53:40`, and
`2026-09-01 22:36:38`.

**The install of 2026-08-31 23:53:25 falls in that gap and produced no arm at
all.** The watcher from 08-30 20:53:40 kept running across it and went on firing
(`23:20:35`, `23:26:01`, `00:29:07`), so for about 23 hours the installed files
and the running watcher were different versions, with nothing saying so.

The mechanism was already written down in `windows/install.ps1` as the reason
`Stop-Watchers` exists -- the watcher is a grandchild (task -> `wscript` ->
`powershell`) and outlives the task being stopped, so it keeps the
single-instance mutex, the newly installed watcher exits on it, and the upgrade
silently goes on running the old code. The install path simply never called it:
`Stop-Watchers` was reachable only from `Suspend-Watcher` (`pause`, `restart`,
the trigger check) and from `uninstall`.

**Why it stayed invisible.** The new watcher's stand-down line -- `another watcher
is already running (Global scope); exiting` -- is also what the 1-minute self-heal
tick writes every minute in the healthy steady state. The failure and the normal
case produce the same log line, and only the ABSENCE of an arm distinguishes
them. `install` now clears the watchers before it registers, and states plainly
when the task is registered with nothing watching.

**Then confirmed live, and fixed.** An install attempt the same morning left the
new scripts on disk with the 09-01 22:36:38 watcher still holding the lock and
still running August's code -- the defect in the open, with the self-heal ticking
`already running` against it once a minute. Re-run with the fix and with
elevation granted, `06:43:12` logged the first new arm since 09-01
(`sessionId=0 interactive=False lock=Global`, so the boot tier survived), the old
process was gone, and the version stamp moved from `3ac7d49, spec revision
unrecorded` to `4ee77df, spec revision 8`.

**Incidental, and its own defect: a declined UAC prompt recorded a downgrade that
did not happen.** `install.ps1:370` writes `install.autostart = login` the moment
elevation is declined, before any task work; the task replacement then failed as
well, leaving the config saying `login` while the registered task was still S4U.
`Get-EffectiveTier` reads that config, so the next bare `install` would have
demoted a working boot tier without anyone asking. Recorded in `TODO.md`; the
fallback is right, writing it before the install succeeds is not.

**2026-09-01 -- the .NET user-environment API cannot round-trip a PATH.**
`[Environment]::SetEnvironmentVariable('X','C:\a;%USERPROFILE%\b','User')`
stores the value as **REG_SZ**, not REG_EXPAND_SZ, even though it contains a
`%VAR%` reference -- checked with `GetValueKind`. And
`GetEnvironmentVariable(...,'User')` EXPANDS such references when the value IS
REG_EXPAND_SZ, because that is what reading one means. Together they read a
user's `%USERPROFILE%`-style PATH entries as literal paths and write them back
that way, with the kind downgraded. A fresh Windows profile's `Path` is
REG_EXPAND_SZ; this desk's is already REG_SZ, which is consistent with it having
happened here. `install.ps1` therefore reads with
`DoNotExpandEnvironmentNames` and writes the kind back itself, and sends
`WM_SETTINGCHANGE` by P/Invoke because a registry write notifies nobody.

**2026-09-01 -- `Get-Content` strips a byte-order mark and the CR of a CRLF
file.** Reading `specs/config-fixture/input.conf`, which carries both on
purpose, `windows/config.ps1`'s single regex reproduced `expected.tsv` exactly
with no explicit handling of either. The macOS reader has to strip both by hand
in awk. Same contract, different amount of code, and the fixture is what proves
the two agree.

**2026-09-01 -- `Start-Process -PassThru` without `-Wait` never populates
`.ExitCode`.** `$p.WaitForExit(ms)` returns `$true` and `$p.ExitCode` reads
EMPTY, not 0. Every suite therefore looked red to `tests/mutate.ps1` and all
seven mutations came back UNJUDGED. `[Diagnostics.Process]::Start` with a
`ProcessStartInfo` gives a handle whose `ExitCode` is real -- and its output has
to be read asynchronously, or a child that fills the pipe buffer blocks and
looks exactly like a hang.

**2026-08-31 -- `[Console]::CursorLeft` clamps.** After `Write-Host ('x' * $w)
-NoNewline` on a `$w`-wide buffer, `CursorLeft` reads `$w - 1`, the same as after
`$w - 1` characters; and writing into the last column wraps. A first measurement
via `[Console]::Write` read "a full-width line plus a newline advances exactly one
row" -- true of that API and not of `Write-Host`.

**2026-08-31 -- a simple function swallows unknown named arguments.**
`Test-Simple -A hello -ThisName world` binds `$A`, leaves `-ThisName world` in
`$args`, and does not throw; a `[CmdletBinding()]` function throws `A parameter
cannot be found that matches parameter name 'ThisName'`.

**2026-09-01 -- neither obvious way to pass an argument list to another script
survives a space.** Against a `[CmdletBinding()]` script declaring `Command`,
`AddToPath`, `ForUser` and `ForAppData`, with the list
`@('install','-AddToPath','-ForUser','HOME\First Last','-ForAppData','C:\Users\First Last\AppData\Local')`:

| form | result |
|---|---|
| `& $f @a` (array splat) | `A positional parameter cannot be found that accepts argument '-AddToPath'` -- splatting an ARRAY binds every element positionally, flag-looking strings included |
| `& $f ` + `($a -join ' ')` | `A positional parameter cannot be found that accepts argument 'Last'` |
| flags bare, values single-quoted with `''` escaping | binds correctly, including a space AND an apostrophe in both the account name and the path |

Quoting a flag name is equally wrong in the other direction: `'-ForUser'` is a
positional string, not a parameter name. This is why `install.ps1` builds its
elevated child's command line through `Format-ChildArguments` rather than a join,
and why the suite round-trips it through a real script instead of asserting on
the text alone.

**2026-10-31, Windows -- boot dependency-loading review of `cfc84ed`, fixed in
`7e65036`.** Fresh Windows PowerShell 5.1.22621.7649 children executed the actual generated
bootstrap, with no trusted Utility module preloaded. Normal startup reached a
bounded harmless child and returned its exit code 7. With only the fixture
process's module path changed to put an isolated substitute
`Microsoft.PowerShell.Utility` first, its `Add-Type` and catch-path `Write-Error`
both wrote markers before restriction; the child did not start and the process
exited 1. The test host supplied process-only execution-policy Bypass. No real
profile module, persistent environment or policy was changed. The normal
search order included current-user, shared and system locations; the explicit
hostile path preceded them. This confirms native command resolution under
those conditions; this initial unelevated reproduction alone does not prove
privilege escalation in S4U.

The bootstrap now embeds a compiled assembly in the administrator-protected
task. Registration uses the direct Framework C# provider, absolute runtime
references to `mscorlib.dll` and `System.dll`, `/noconfig /nostdlib+`, and default
`TempFileCollection` protection/cleanup. Boot disables module autoload and uses
in-memory Framework operations through token restriction; failure writes to
`Console.Error`, without command lookup or a user log. No compiler, output DLL
or installed-code read is required by that startup script. The native token
restriction C# source is unchanged.

The dependency review covered the compiler, assembly and compression path.
The compiled assembly references only the two strong-named Framework
assemblies. Microsoft's [Framework temporary-file implementation](https://github.com/microsoft/referencesource/blob/main/System/compmod/system/codedom/compiler/TempFiles.cs)
creates protected high-integrity scratch space when elevated; specifying a
custom temp directory would bypass that default. The Framework's
[compression loader](https://github.com/microsoft/referencesource/blob/main/System/InternalApis/NDP_FX/inc/ZLibNative.cs)
selects `clrcompression.dll` by its absolute runtime-directory path. Native
fixtures also supply invalid DLL/compiler bait in the working directory/PATH
and an isolated TEMP/TMP. PowerShell itself creates an empty missing TEMP even
for `exit 0`; that host behavior is separate from compiler activity.

`bootstrap-dependencies.tests.ps1` failed against the unchanged production
code at the substitute-module assertion. Its fresh-process adversary control,
success path and restriction/assembly/decompression failures now pass. Both
mutations restoring untrusted compiler/error command resolution are caught by
actual fixture markers, alongside the 12 existing affected boot mutations.
The privileged-user-log mutation still fails its original assertion, using a
direct Framework append to exercise that defect with module autoload disabled.

The approved native UAC assertion correction was also reproduced under an
actual standard account: native membership was false while credential-prompt
eligibility was true. The independent `whoami`/claims assertion is retained;
eligibility now has an independent registry-policy expectation. That focused
native standard-account check passes. Existing native policy fixtures cover
enabled/deny-only administrator membership and permitted, denied, missing or
unreadable standard-user policy. Three standard-user and three elevation
mutations were caught. The full publication file's sandbox-standard run then
encountered unavailable CIM access; it is not recorded as a full-file pass in
that context. The owner-context native publication file passed.

Native comparison also showed `GetTempPath` preserving an 8.3 alias in the
standard context while expanding it in the owner context. The Unicode
transcript assertion is retained with an explicitly Unicode TEMP path; a
separate alias case verifies the same isolated directory and child exit code.
No product assertion was relaxed. Existing profile, reboot and physical
observations remain tied to their candidates and unchanged behavior. No new
physical write or installation is established by these fixtures.

From the repository root, native `powershell.exe -NoProfile -ExecutionPolicy
Bypass -File windows/tests/run.ps1` passed all 22 files without skips, including
parsing/conventions and transport enumeration/WhatIf. The same host with
`-File windows/tests/mutate.ps1 boot`, `standard-user` and `elevation` caught
14, 3 and 3 mutations respectively. These are fixture/native OS results, not
new observations of physical switching.

**Bounded S4U check, 2026-10-31 09:47 UTC.** With one coordinated UAC approval,
four uniquely named S4U/Limited tasks, each capped at 30 seconds, exercised the
actual privileged session-0 context. The saved original bootstrap, with only
fixture paths substituted, resolved both hostile Utility functions and exited
1 without a child; its recorded parent had enabled administrator membership,
the intended owner and session 0. The secured bootstrap ignored those modules
and DLL/compiler bait, launched the identity-only child and returned its exit
code 7. That child's actual token retained the intended owner/session, medium
integrity, no enabled administrator/power-user membership and only
`SeChangeNotifyPrivilege`. Forced restriction and assembly failures exited 1
without a child, module marker or privileged user-log write. This supplies the
affected S4U-context evidence absent from the initial reproduction.

All four tasks were removed. Before/after hashes and state checks matched for
the current saved configuration, installed stamp, task XML/enabled/running
state, watcher lock and user PATH. The owner confirmed a configuration edit
during this investigation; those current bytes were preserved, not replaced
by an older backup. The source snapshot tested in session 0 matched
`windows/lib/user-launch.ps1` SHA-256
`4EDD6073A6766B17AAB9331669F866C9C16DCCDA1E1E527288AF7F2AF43221FB`.
Private task/token receipts are retained outside tracked files. No account
rights, live installation, reboot or monitor inputs were changed by that
fixture session. The subsequent coordinated upgrade below regenerated the
installed task; a watcher restart alone does not regenerate it.

CI for `7e65036` (validation record retained privately)
passed both jobs. Inspection with `gh run view 41190219699 --log` confirmed
Windows PowerShell: 21 files passed, `resolve.tests.ps1` skipped without NVIDIA
hardware, and two real-driver cases explicitly skipped; macOS: all 13 files
passed. These hosted results do not replace the local 22-file no-skip run or
physical observations. The final coordinated release candidate and separate
privacy review remain open gates.

**2026-10-31, 03:14 PDT (10:14 UTC) -- installed upgrade to `6f65aff`.** The
owner authorized the supported installer and UAC prompt. A clean detached
checkout supplied the candidate; the main checkout's pre-existing local work
was preserved. Private backups captured the then-current configuration, program
files, task XML and PATH, with clean `6a5afcf` source prepared for recovery.
In the original owner's elevated Windows PowerShell 5.1 context, the installed
shim's `pause` was followed by `powershell.exe -NoProfile -ExecutionPolicy Bypass
-File .\windows\install.ps1` from the clean candidate. The installer exited 0;
rollback was not needed.

All installed script hashes and the stamp matched `6f65aff`, product 0.2.0 /
specification 15. Current configuration bytes and PATH matched their private
pre-upgrade snapshots exactly. The protected task contained the embedded
assembly bootstrap with module autoload disabled and zero PowerShell command
AST nodes. The intended owner's S4U/Limited task was enabled with a boot
trigger, and exactly one owned watcher held its lock. Its actual token was in
session 0 with medium integrity, no enabled administrator/power-user membership
and only change-notify privilege. The installed shim's `status` succeeded;
independent post-session checks confirmed source identity, preservation, task
state, secured bootstrap and watcher lock. No account rights, reboot or monitor
inputs were changed. This is installed/native OS evidence, not a new physical
switching or pre-login reboot observation. Private backups and receipts remain
outside tracked files.

**2026-10-31, 05:02 PDT (12:02 UTC) -- installed upgrade to `ab82fce`.**
The owner authorized the supported installer and UAC prompt. A clean detached
checkout supplied `ab82fce`; clean `6f65aff` source was available for rollback.
Private backups captured the current configuration, installed program, task XML
and PATH. The installed shim's `pause`, followed by native Windows PowerShell
5.1 `-NoProfile -ExecutionPolicy Bypass -File .\windows\install.ps1` from the
candidate under the original owner's elevated context, completed with exit 0.
Rollback was not needed; the main checkout's existing local work was preserved.

Every installed script hash matched the candidate. The stamp records
`ab82fce` / product 0.2.0 / specification 16. Configuration bytes and user PATH
matched the private pre-upgrade snapshots exactly. The intended owner's
S4U/Limited task was enabled and running with a boot trigger, and exactly one
owned watcher held its lock. Its actual session-0 token had medium integrity,
no administrator/power-user membership and only change-notify privilege. The
rebuilt bootstrap retained disabled module autoload and zero PowerShell command
AST nodes. Installed `status` succeeded; independent unelevated checks confirmed
the stamp, saved boot tier, configuration/PATH preservation, task and lock state.
No profile, account-right, reboot or monitor test was repeated. This is installed
and native OS evidence, not a new physical-switching or pre-login observation.
Private backups and receipts are retained outside tracked files.

## Menu viewport

**2026-10-31 -- terminal height, synthetic lists, macOS.** The installed menu
library matched the source at `cfc84ed`. With 30 synthetic entries in a 12-row,
80-column PTY, single-choice and multi-select drew 32 and 34 rows respectively.
The first selected row was outside the visible viewport, although scripted
navigation still returned index 0. Both primitives repainted the full list;
terminal height did not constrain their frames.

The revision-16 implementation uses the same viewport for both primitives.
Repeating that bounded PTY reproduction returned index 0 in each, kept the
initial highlight visible in the screen model and issued only 11-row cursor-up
redraws. New regressions failed against the original renderer before the fix.
Fixtures cover wrapped details and Unicode, disabled/separator rows, Done,
page/end navigation, resize and numbered fallback retaining choices. Native
PTY tests also exercise the actual escape sequences and a 12-by-80 window
resized to 9-by-55. This evidence concerns synthetic terminal interaction;
no monitor, installed watcher or owner configuration was changed.

`cd macos && make test` passed all 14 files and shellcheck with native PTY/
process access, without skips. `bash tests/mutate.sh lib/menu.sh` caught all 18
existing menu mutations; after correcting two new mutation expressions,
`bash tests/mutate.sh viewport` caught all six viewport mutations against a
passing baseline. A completion guard in the new regression file also rejects
an early zero-status Bash exit before all cases run. Sandboxed PTY/lock failures
were not counted as product evidence; the complete native run above passed.

## Windows follow-up review

**2026-10-31 -- revision-16 menu viewport, Windows PowerShell 5.1.22621.7649.**
At `8564b05`, a bounded hidden native console with 30 synthetic entries and a
12-row, 80-column window reproduced the Windows defect before production edits:
the single-choice menu scrolled its first highlight away, leaving rows 21-29
and the hint visible. Its native regression failed at the visible-highlight
assertion. The existing menu assertions were retained.

Both common primitives now use one physical-row viewport, reserving controls,
wrapped help/validation text, an overflow range and a cursor row. Explicit
folding also handles a buffer wider than the visible window. A resized frame
is erased through bounded buffer rectangles, without rewinding the old height
through a smaller window. Selection/check state survives scrolling, reflow and
numbered fallback; no identifiers are shortened. Done belongs to navigation,
and separators/disabled entries keep their original positions.

Native measurement found that RawUI `LengthInBufferCells` returned 1 for a CJK
character while `Write-Host` advanced the cursor by 2. RawUI buffer reads also
returned that glyph twice as `Complete` cells, rather than a leading/trailing
pair. Latin-1 accented text advanced one cell; a supplementary character and
a combining sequence each advanced two. The renderer bounds code units beyond
Latin-1 conservatively and explicitly folds before painting. An indivisible
text element exceeding the safe width uses the complete numbered transcript.
The Unicode regression checks exact text passed to the real host, a visible
terminal token and actual frame/highlight bounds; it does not interpret those
duplicated RawUI cells as lost/duplicated source characters.

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File
windows/tests/run.ps1 viewport` passed 30 cases in actual hidden console
windows. Scripted `ConsoleKey` values drive the unchanged input boundary;
buffer cells, cursor positions, window/buffer dimensions and resize operations
are native. Coverage includes 12x80, 10x55, 16x80, 8x80, 6x24 and 14x80 windows,
a 120-column buffer behind an 80-column window, wrapped details/help/Done,
disabled/separator rows, page distances/end clamping, arrow wrap, empty-Done
refusal, resized fallback and Escape/selection preservation. These are automated
console fixtures, not manual keypress or physical-monitor observations.

The resize-to-fallback boundary has three additional Escape cases. Native
reproduction showed that an Escape arriving with an undersized resize was
consumed before the numbered prompt. The transition now honors submenu
cancellation immediately, or moves the top-level default to Cancel while
still requiring confirmation. Multi-select cancellation discards in-progress
checks at that boundary too; two specific mutations remove those protections
and fail the native cases.

Using the same native host, `windows/tests/mutate.ps1 viewport` caught all 16
new mutations; the refined current-highlight mutation was also rerun separately
and failed specifically after moving the selection. Filters `menus` and
`redraw` caught all 3 and 2 existing mutations. The full suite before advancing
`SPEC-REVISION` passed every file except the expected revision-15/16 ledger
failure. No live installation, account, watcher, reboot or monitor setting was
changed; previous installed/hardware evidence remains tied to its candidates.
After advancing Windows `SPEC-REVISION` to 16, the complete native command
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/tests/run.ps1`
passed all 23 files without skips, including parsing/conventions, conformance
and the native viewport cases. Product version remains 0.2.0.

**2026-10-31 -- Windows follow-up review at `f4bacab`, from macOS.** Source,
regressions and the recorded native evidence address all three findings in the
preceding handoff: pre-restriction PowerShell module loading, the native UAC
eligibility assertion and the stale boot-validation documentation. Hosted run
`41192088119` passed: macOS 13 files, Windows 21 files with the native resolve
file and two driver cases explicitly skipped. The Windows record separately
reports all 22 files and 20 relevant mutations passing on native PowerShell
5.1, bounded S4U bootstrap control/success/failure checks and the supported live
upgrade to `6f65aff`. Those native actions were not repeated on this Mac.
No additional blocker was found within that follow-up's scope. Windows menu
height support was outstanding at that review and is addressed by the native
evidence above; privacy and coordinated release checks remain separate gates.

## Release validation and privacy

**2026-10-31 -- macOS 0.3.0 preparation and documentation review.** The
preparation worktree is based on `065cc0f`; the only runtime change is
`TK_VERSION` from 0.2.0 to 0.3.0. Both specification revisions remain 16.
`cd macos && bash tests/install.tests.sh` passed, followed by `make test`:
all 14 native test files and ShellCheck passed without skips. Native PTY and
process access were available. `bash tests/mutate.sh publication` caught all
11 mutations against passing baselines; hashes of every tracked file matched
before and after the mutation run. Raw receipts remain private.

The shared README was reviewed through GitHub's file-style Markdown renderer
at desktop and narrow widths, with local link/heading checks. Its setup and
everyday-use sections point to platform guides for the full command surface
and implementation details. The owner confirmed there are no linked GitHub
Projects, closing that audit access gap by owner confirmation, not API access.
No installed watcher, configuration, task, account, monitor or startup state
was changed. Windows version preparation and native validation of the final
coordinated candidate remain in `windows/HANDOFF.md`; no tag or publication
is implied by these checks.

**2026-10-31 -- native Windows checkout migration at `2551331`.** The fresh
sanitized clone was promoted to the top-level development workspace; the old
checkout, its local edit, private validation/installation backups, linked
worktrees and duplicate clone were archived outside it. Windows refused some
Git directory renames, so metadata files were moved with hash verification;
the resulting object database matches the fresh clone, with no extra Git files,
object alternates or imported old refs. The old head is absent, `git fsck --full
--no-reflogs` passes, and the clean branch matches `origin/main`. Archive
worktree pointers were repaired without importing them into the active clone.
Repository-local email uses the maintainer's GitHub noreply identity.

On Windows 11 build 22631, Windows PowerShell 5.1.22621.7649 ran
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\tests\run.ps1`:
all 23 test files passed without skips, including the synthetic display-row
fixture, native process/console cases, parsing/conventions and specification
conformance. Existing assertions were unchanged. Saved configuration bytes,
installed version-stamp bytes, user PATH and exported task definition matched
the private pre-migration snapshot; the boot task remained enabled/running.
The local edit was preserved byte-for-byte in the archive. No installer,
monitor write, account change or reboot was performed. This verifies the
sanitized checkout and unchanged installed state, not a new physical switch
or final coordinated release. Raw receipts remain private.

**2026-10-31 -- owner-authorized, history-preserving privacy cleanup.** The
pre-rewrite audit covered 121 current files, 251 commits, 1,363 text blobs,
the annotated tag, and 39 Actions runs with 40 available log attempts. A direct
comparison with original measurement values found one real LG serial still in
`windows/tests/identity.tests.ps1`; its display-row fixture now uses `00001111`,
with every assertion retained. No credential leak was confirmed. Gitleaks'
generic-key alerts in the source were filename-list assignments, not secrets.

An isolated rewrite retains every commit, parent relationship, author and
committer name, and timestamp, while replacing identifying values and using
the maintainer's GitHub noreply email in commit and tag metadata. All 1,363
old/new blob pairs were compared against the intended substitutions and commit
reference updates. The annotated `v0.2.0` tag's name, tagger name/date/message
and corresponding target were checked. Twenty-two deliberate identifier
reintroductions were caught by the private validation scan. Recovery bundles,
replacement rules, old/new mappings and all downloaded Actions evidence are
retained privately. Old CI links refer to those retained validation records;
affected runs are removed as part of the authorized remote cleanup.

Validation on the sanitized source: `cd macos && make test` passed all 14 test
files and ShellCheck without skips. The Windows identity test passed under
PowerShell 7 on macOS; native Windows validation is supplied by hosted CI and
the Windows checkout migration, not inferred from that portable run. Safe DDC
allowlist values and current instruction files are byte-identical. Runtime
changes are limited to comments referring to rewritten commits; no installed
configuration, watcher, monitor or autostart setting was changed.

The owner accepts that rewriting published refs does not prove deletion of
cached/unadvertised server objects or outside copies. This decision supersedes
the earlier withholding of privacy-remediation approval, not the requirement
for separate publication/release approval. `docs/privacy.md` gives the policy,
limits and fresh-checkout instructions. Product version remains 0.2.0 and
specification revision remains 16; 0.3.0 is the next coordinated release target.
The dated audit entries below describe their original review scope; historical
examples and commit references are now sanitized.


**2026-10-30 -- privacy audit at `2835cb0`, while the repository remains
private.** Read-only inspection covered all 112 tracked current files and
every blob reachable from the local refs: 226 commits and 1,192 text blobs,
with no binary blobs. Remote enumeration advertised only `main` and `v0.2.0`,
both present locally. Commit messages and author/committer metadata were also
checked. Pattern checks covered known credential formats/private keys,
credential assignments, email/profile paths, Bluetooth addresses, serials,
UUIDs, device-instance and topology paths. No known credential-pattern match
was found; pattern scanning is not a guarantee that every possible secret is
absent. Current matches were reviewed as synthetic fixtures/placeholders,
redacted measurement labels or public API constants.

Historical device identifiers/profile paths remain in earlier file versions.
Locations include `docs/measurements.md`, `displays.toml`,
`ideas/telling-two-identical-devices-apart.md`, `macos/README.md`,
`windows/HANDOFF.md`, `windows/README.md`, `windows/trigger-kvm.ps1` and older
Windows test fixtures. Raw matches and object IDs are retained privately;
identifying values are not repeated here. One non-noreply author email remains
in Git metadata and in GitHub Actions run metadata. Human authorship was not
changed, and no history rewrite was performed.

The GitHub API reported one branch and one tag; no issues, pull requests, issue/
review/commit comments, releases or Actions artifacts. Wiki, Pages and
Discussions were disabled. All 14 existing Actions logs were retrieved and
scanned; no additional credential or personal-identifier matches were found
in those logs. Repository/Actions metadata was inspected separately, including
the retained author email. GitHub secret scanning was disabled and its alerts
endpoint unavailable. Unadvertised/deleted server-side objects and external
copies are outside this audit's visibility.

A follow-up scan through documentation commit `a05876b` covered 227 commits
and 1,196 text blobs, with no binary blobs or new finding categories. The
additional Actions run's log was also checked; its matches were hosted-runner
paths and generated UUIDs. The historical publication decisions below remain
open.

Publication still requires the owner's decision to retain the historical
identifiers and author email, or to commission a separately approved privacy
remediation with a concrete preview. This audit does not authorize changing
metadata, credentials, history or repository visibility. Repeat the applicable
checks on the final release candidate and any newly created remote surfaces.

The post-reboot refresh through `3d3fe8a` covered 230 commits and 1,213 text
blobs, with no binary blobs or new finding categories. All 18 available Actions
runs' logs were scanned; matches were hosted-runner paths and generated UUIDs.
The repository remained private with one branch, one tag, no issues/comments,
pull requests, releases or artifacts, and Wiki/Pages/Discussions disabled.
The secret-scanning endpoint remained unavailable. Historical identifiers and
the author email remain the same unresolved publication decisions.

The refresh through `462204a` covered 113 tracked files, 232 commits and
1,234 text blobs, with no binary blobs. The only new pattern match was a
synthetic device-instance fixture in `windows/tests/privilege.tests.ps1`;
there were no new commit-message candidates or authorship records. All 20
available Actions runs' logs were scanned. Repository metadata's apparent
profile-path matches were GitHub user API links. The remote surface counts,
secret-scanning limitation and unresolved historical publication decisions
were unchanged. Earlier raw reports were preserved privately before refresh.

On 2026-10-30 the owner chose to keep publication blocked for a separate privacy
review. Historical identifier and author-metadata retention is not approved for
publication. No history rewrite, author-metadata change or visibility change is
authorized by that decision.

The refresh through `473274d` covered 237 commits / 1,279 text blobs, with no
binary blobs, and all 25 accessible Actions logs. Comparison with the prior
private inventory found no new current/history/remote identifying values or
authorship records. The repository remained private with one branch and one
tag; other remote surface counts were unchanged. Secret scanning remained
unavailable. The owner's separate privacy-review block remains in force.

The 2026-10-30 refresh through `1f00e7e` covered 242 commits / 1,298 text blobs,
with no binary blobs, and all 30 accessible Actions runs' logs. Earlier reports
were retained privately. Comparison found no new current/history/message
finding pairs, authorship records or remote category/value pairs. Remote surface
counts and the secret-scanning limitation were unchanged. This is an audit
delta, not approval to publish the historical identifiers or author metadata.
