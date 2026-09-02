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

**The LG's EDID product id is per-INPUT, and not per-host.** Four consecutive
values on the one panel: `0x9e9d` (Windows, DP), `0x9e9e` (Intel Mac, HDMI 1),
`0x9e9f` (Mac, USB-C), `0x9ea0` (Mac, through the old KVM). It was once recorded
here as "each stable for its own host", which left open whether the id followed
the input or the machine. On 2026-09-01 the Intel MacBook, on the LG's USB-C
input, read `0x9e9f` -- the same value the Mac Studio reads on that same input.
So the input decides it, and a host still may only use the value it measures on
its own input.

Around it: the EDID *serial* (`0x00001111`) is stable across all of them, while
the EDID's own length is not -- 384 bytes on USB-C, 512 on HDMI 1. And because
`CGDisplayCreateUUIDFromDisplayID` derives from the product id, the UUID m1ddc
keys on is per-input as well (`aaaaaaaa...` USB-C, `bbbbbbbb...` HDMI 1). The
ASUS reports `0x42e0` everywhere, and its UUID was correspondingly identical
across two readings on one input.

**2026-08-31, macOS -- display identity needs no session.** From a LaunchDaemon
with `UserName` set and no logged-in session: IOKit display identity worked with
no CoreGraphics, `m1ddc display list` worked, and a full `trigger-kvm pull` ran
as uid 501 with both writes sent.

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
It printed `1E6D|9E9E|GSM||00001111|<uuid>|` for the format
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

All taken 2026-09-01 on the Windows PC (i9-13900K / UHD 770, ROG STRIX Z790-A
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
NVAPI enumerated: outputId=0x00000200 connector=DisplayPort edid=0x1E6D:0x9E9D serial=0x00001111
```

which is the correct behaviour -- it declined rather than mis-aiming -- but it is
also the whole limitation: today an NVAPI-only Windows install covers only
panels on the NVIDIA card.

**2026-09-01, Windows -- session 0 gives dxva2 no usable handle, with the ASUS
on the Intel output.** From an unelevated S4U on-demand task (`tk-dxva2-s0`,
principal `rishe`, `LogonType S4U`, `RunLevel Limited`, `LastTaskResult 0`),
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
instance path from `DISPLAY\AUS42E0\5&aaaaaaaa&0&UID4352_0` to
`DISPLAY\AUS42E0\4&bbbbbbbb&0&UID49_0`, and its GDI name from `\\.\DISPLAY1` to
`\\.\DISPLAY7`. The `AUS42E0` component -- EDID vendor `AUS` (`0x06B3`) plus
product `0x42E0` -- was unchanged, as was the EDID serial `AS0000000001`. Putting
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
