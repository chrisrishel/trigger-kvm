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
ONE standard `GetVCP 0x60` on source `0x51` per external framebuffer; and with
`--set-asus-input` it sends ONE standard `SetVCP 0x60` to an AUS panel, from a
named allowlist, gated on the EDID vendor. **Nothing was ever sent on source
`0x50` from that machine, and the LG was never written to at all** -- `0x50` and
`0xF4` do not appear anywhere in that program outside a comment. The MacBook's
own screen held the terminal throughout, so hard rule 4 was never in play.

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

**Not measured, deliberately -- and the LG is the whole of it.** Everything above
is the STANDARD channel. Nothing was sent on source `0x50`, so **whether the LG
accepts `0xF4` over this route is unknown**, and that is the question Intel
support actually turns on: the LG's standard `0x60` is stubbed in the panel, so
the sidechannel is the only way to move it and no amount of standard-DDC success
substitutes. A machine that could switch the ASUS and not the LG would be the
half-switching setup that presents as a hardware fault.

One more thing the ASUS write did NOT prove: `tests/conventions.tests.sh`, which
asserts hard rule 5's gate is the only door, scans `lib/` and `trigger-kvm` --
**shell only** -- and keys on the literal string `input-alt`, m1ddc's spelling. C
code emitting the source byte numerically would contain no such string, so the
scan would count one door and pass while a second existed. Extending that scan is
a precondition of any Intel write path, not a follow-up to one.

The USB-C-to-DisplayPort-direct reading the brief asked for was not taken: it was
the tie-breaker for an ambiguous result, nothing was ambiguous once both DP Alt
Mode and an HDMI protocol converter carried DDC, and it is the only one of the
cablings that would have cost the PC its LG connection. The 13" 2019 model's
Intel-GPU framebuffer path is untested. Nothing was tried on source `0x50`.

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
