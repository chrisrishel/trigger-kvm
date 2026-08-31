# Agent instructions

Read this before changing anything in this repo. Start with `ARCHITECTURE.md` for
the design and `displays.toml` for the values.

## What this project is

Two machines (Mac Studio, Windows PC) share two monitors with **no KVM in the video
path**. Each machine connects directly to both monitors. A USB switch moves the
peripherals; whichever machine receives them commands both monitors over DDC to
select its own inputs.

Every platform implementation is the same two roles: a **detector** (do I own the
peripherals now?) and a **switcher** (make the monitors show me).

## Hard safety rules

**1. Never sweep or brute-force VCP codes on I2C source address `0x50`.**
That is a service/factory channel. Sweeping it has bricked LG monitors — the
`ddcutil` repo carries an issue titled "Bricked LG Monitor". Use only the values
already documented in `displays.toml`. If you need a value that isn't there, ask;
do not go looking for it experimentally.

**1a. A monitor's inputs are named after the COMPUTERS on them, and that one map
answers both verbs.** `display.lg.input.0xD1 = mac`, `computer.this = pc`. `pull` is
`to <computer.this>`; same lookup, same code path. There is no `scene.*` and no
`display.<label>.self` -- both were deleted, because two representations of "machine
M is on input V of display D" can disagree and one cannot. `to` is still MANUAL
ONLY: a trigger may never reach a name other than `computer.this`, because a name
describes hardware this machine cannot observe.

**1b. A manufacturer dialect is OFFERED, never probed, and only after standard
DDC/CI has been shown not to work.** `$DIALECTS` in `install.ps1` is keyed by EDID
**vendor** -- never vendor:product, which was one row per monitor someone here
happened to own. Values in it come from documentation and measurement. The
walkthrough sets every panel to `standard` first, whatever the make; only when the
user reports that nothing happened is the vendor's channel offered, with its values
shown. Blind value-walking is standard-DDC-only, one MCCS value at a time, offered
with its cost stated, and refused when it would take the last display.

**2. Never verify a switch by reading a VCP value back.**
Reads are unreliable on both monitors and *have already produced false negatives*:

- **PG42UQ** returns `0` for luminance, contrast, volume **and** `max luminance` —
  always, whether or not it is the active input. Writes still work perfectly.
- **LG** returns real values on a settled active link, but `-7` while the link is
  inactive or renegotiating. It read `-7` immediately after a switch that had in
  fact succeeded, then recovered to `100` seconds later.

Writes are fire-and-forget. Do not build verify-then-retry loops; they will fire
spurious retries. Do not probe immediately after a switch.

**3. You cannot see the screen. A switch is only confirmed by a human looking at
it.** Never report that a switch worked because a command returned success or a
read looked right — both have lied here. Ask the user to confirm visually, and say
plainly when something is unverified.

**4. Never leave the user without a working display.** Switching both monitors to
the other machine blacks out this one. When testing, move one monitor at a time and
keep the other on the machine running the terminal. Warn before any command that
takes the last remaining display.

Note the corollary from `ARCHITECTURE.md`: because the link stays enumerated, a
window on a monitor you just switched away is still *there*, just invisible. Before
moving the monitor the terminal is on, have the user drag the terminal to the other
one first.

**5. The LG service channel may only ever be aimed at the LG.**
I2C source `0x50` carries VCP `0xF4`, and what that means on a non-LG panel is
unknown. The rule is enforced in code, at the transport, not by caller discipline:
`NvDdc.WriteLgInput` in `windows/trigger-kvm.ps1` is the only function that can
emit source `0x50`, the source byte is not a parameter, and it **throws** unless the
target's EDID manufacturer is GSM (`0x1E6D`). There is no generic "write to source
N" entry point, so no caller can aim it at another vendor's panel, including by
accident. Do not add one.

The switcher also refuses the LG switch unless exactly one enumerated output
identifies as the LG — zero is a refusal, and so is more than one, because an
ambiguous target cannot be aimed at safely.

**Historical, and the reason for the rule's shape.** Until 2026-08-30 the LG was
driven by `lg-input-switch.exe`, whose `_i2c_write` loops over every connected
output mask and ports 0-7, sending the packet to all of them. It did not identify
the LG, so with both monitors on one GPU `lg-input-switch dp` also delivered
`SetVCP 0xF4` to the **ASUS**. A `Test-LgBlastRadius` guard compensated by refusing
whenever any panel outside `GSM9E9D`/`AUS42E0` was attached — which meant attaching
a third monitor stopped LG switching entirely. Both the spray and the guard are gone:
an aimed write has no blast radius, so a third monitor is now simply irrelevant.

The old measurement is still worth keeping, because it is the only evidence anyone
has about what `0xF4` does to a PG42UQ: the ASUS ignored it, with no flicker or
setting change, confirmed with the ASUS write **isolated out** (a `-Only lg` run, so
the spray was the only traffic on the wire). That was a property of that specific
panel, never a general licence — and it is no longer relied upon.

**Expect the LG to flicker briefly on every LG switch, including a re-assert to the
input it is already on.** It is re-negotiating the link, and each write is sent
twice by design (the bus is lossy). This is normal and was mistaken for a fault
once already — do not go looking for a bug in it.

## Known limitations, both platforms

Neither of these is a bug to fix on sight; they are things to know before changing
the detectors, and to reach for first if a spurious switch is ever reported.

**A force-killed watcher leaves the lock ABANDONED, and that is a normal condition
here -- not an error.** `install.ps1` force-kills the watcher on every install,
because stopping the task only kills the `wscript` shim and leaves the watcher
running as its grandchild. Task Manager and a crash do the same. .NET signals this
by throwing `AbandonedMutexException` from `WaitOne` **after** handing the lock
over; `event-watch.ps1` catches it and continues, because the alternative is an
install that registers the task, reports success, and leaves nothing watching.

Verified rather than assumed: after catching it, `ReleaseMutex()` succeeds -- which
only works if the lock is genuinely owned -- and that release consumes the
abandonment so the next start sees a clean lock.

Do not "simplify" the catch away. Uncaught, it also strands the lock when the
watcher is run BY HAND, because an aborted script does not end an interactive
shell: the acquiring thread lives on still owning it, and every later watcher then
reports "another watcher is already running" until that window is closed.

**One physical USB plug produces DOZENS of `Win32_DeviceChangeEvent` indications,
not one.** Measured 2026-08-30: plugging a single device in generated 32 events in
about three seconds, and unplugging it another 13. The event carries no device
identity, so each one costs a `Win32_PnPEntity` query to find out what happened.

Two consequences. The debounce is not belt-and-braces against a flaky switch, it is
load-bearing for ordinary operation -- without it a single arrival would fire the
switcher dozens of times. And the no-edge branch is the common case by a wide
margin, which is why its log line is `Write-Verbose` and not `Write-Log`; promoting
it would bury the log in noise on every plug.

**PnP presence means "attached" for USB and "PAIRED" for Bluetooth. Do not extend
the watcher to Bluetooth by widening its match pattern.** `event-watch.ps1` assumes a
node exists only while the device is attached, so an absent -> present edge means
arrival. Measured 2026-08-30: a pair of AirPods whose
`DEVPKEY_Bluetooth_LastConnectedTime` reads **2025-11-07**, and an iPhone reading
**2023-07-07**, both still report `Present=True`, and both carry
`DEVPKEY_DeviceContainer_AlwaysShowDeviceAsConnected = True`. The presence map would
never change, no edge would ever fire, and the trigger would silently never work --
the worst failure shape available here.

The downstream function nodes do track connection (those AirPods' `SWD\MMDEVAPI\`
audio endpoints read `Present=False` while the parent reads `True`), but they are
opaque GUIDs, differ by device class, and appeared twice on this machine under two
different service-id forms. Matching them is guesswork.

**The watcher is ONE process with N event sources. Do not add a second persistent
process, and do not tell users to run one.** Two watcher processes would each hold
their own in-memory debounce and both fire when a USB device and a Bluetooth device
arrive together -- the double-fire the `Global\` mutex exists to prevent, and which
that mutex would in fact block by stopping the second watcher.

The same applies to non-device triggers, for a different reason. "A hotkey can just
run `trigger-kvm.ps1 pull`" is true architecturally and a poor answer practically:
it makes the user install and supervise a SECOND background app to do a job this
process could do. Every extra always-running thing is another install step and
another way for the setup to end up half working. Sources belong here; the command
interface stays as the integration point for things not implemented here.

Sources differ in what constitutes a fire, and that is per-source, not a reason to
split. Device presence fires on an absent -> present EDGE and needs debounce and
settle, because a spurious arrival would yank the displays. A hotkey is deliberate
and discrete and needs neither. What sources share is the process lifetime, the
single-instance lock, and the fire.

**Whatever the source, it runs `pull` -- never another computer's name.** A name
other than `computer.this` describes inputs on hardware this machine cannot observe,
so a stale one must never be reachable from anything automatic.

**On macOS, Bluetooth presence comes from `system_profiler`, and the reason is a
PERMISSION GATE rather than a broken API.** IOBluetooth needs TCC Bluetooth
permission, granted PER BINARY. An unapproved binary's first call BLOCKS until a
human approves a prompt, and that prompt can arrive minutes later. Once approved
it works fine -- from a terminal and from a LaunchAgent alike. Measured
2026-08-31 both ways with one probe binary: 10 paired devices with connected
state, no run loop needed, exits cleanly.

What makes it unusable here is the FIRST run on a fresh install. The watcher's
first Bluetooth sweep would block until someone noticed a prompt, with the
process still ALIVE -- so `KeepAlive` would not restart it, and the trigger would
silently never fire until it was answered. A background watcher must not wait on
a human.

`system_profiler SPBluetoothDataType -xml` never raises that prompt: it is
Apple-signed and carries its own entitlement, which is why it answered on the
very first attempt here, before any prompt had been seen. It costs about 60ms
and is a property list, so CoreFoundation parses it with no JSON dependency.
There is no notification to subscribe to on that route, so Bluetooth is POLLED --
and only when a `bt:` device is configured, so a USB-only setup pays nothing.

**A HANG UNDER TCC IS INDISTINGUISHABLE FROM A SLOW PROMPT. Do not conclude
anything about a permission-gated API from a timeout.** This entry was wrong
TWICE before it was right: first "the API never returns" (measured with an
unanswered prompt behind it), then "a LaunchAgent can never get permission"
(measured in a 15-second window, and the prompt simply had not arrived yet).
Both readings were confidently stated and both were artefacts of the measuring
window. If something TCC-gated appears to hang, look for a pending prompt before
concluding anything -- and prefer the route that needs no permission at all.

**Bluetooth is BUILT, and matches on CONNECTED, never on paired.** `event-watch.ps1`
takes `bt:AAAAAAAAAAAA` entries alongside `usb:VVVV:PPPP` (and bare `VVVV:PPPP`,
which still means usb). Connection state comes from the classic Win32
`bthprops.cpl` API by P/Invoke -- `BLUETOOTH_DEVICE_INFO.fConnected`, distinct from
`fRemembered`.

**But the CANDIDATE LIST offers every PAIRED device, connected or not.** Two
different questions, and conflating them cost a round: firing is on connected,
*offering* is on paired. A trigger fires on arrival, so the device that is
disconnected right now is exactly the one that will produce one -- filtering the
list to connected-only hid the choice a user most wants. Show the state; do not
filter on it.

Do not "simplify" it onto the PnP path. Three routes were tried and ruled out first,
and the reasoning is not obvious:

```
widen the PnP match pattern    NO -- PnP presence means "paired", and a paired
                                     device keeps its node for YEARS
Register-ObjectEvent on WinRT  NO -- "Windows PowerShell cannot subscribe to
                                     Windows RT events"
Add-Type referencing .winmd    NO -- 0x80131047, cannot load winmd
P/Invoke the classic API       YES
```

Two implementation constraints that are easy to undo by accident:

- **Enumerate Bluetooth ONCE per presence sweep**, not once per watched device. The
  API walks the whole paired set every call, and a single USB plug produces ~32
  change events, each triggering a sweep.
- **A missing or disabled radio must not take the watcher down.** It is caught and
  treated as "nothing connected", which is an absence, and absences never fire. The
  USB half has to keep working.

Volume differs by an order of magnitude between transports, which matters if timings
are ever tuned: a USB plug produces ~32 events, a Bluetooth connect about 3.

**WMI device notifications DO reach session 0.** Measured 2026-08-30 from an
unelevated S4U task: 45 indications in 90s, and `Win32_PnPEntity` presence queries
work there too. This is what makes the pre-login tier viable rather than a silent
failure -- the switcher was already proven in session 0, but a detector that never
fires would have been worse than one that errors. The reason it works: the watcher
uses `Win32_DeviceChangeEvent`, a WMI extrinsic event from the Winmgmt service,
**not** `WM_DEVICECHANGE`, which is a window message and would need a desktop. Do
not "simplify" the detector onto window messages; it would break the s4u tier
silently and post-login would keep working, so nobody would notice.

**Only one device ever appears in the log, and that is correct.** Both watched
devices arrive together when the USB switch moves. Whichever lands first fires; the
other falls inside the debounce window and is discarded. In practice the Focusrite
wins and the webcam is never logged — observed on both platforms. This is the
debounce working, not the webcam failing to register. Do not "fix" it, and do not
read a single-device log as evidence that the other device is misconfigured.

**Sleep/wake does NOT fire a spurious switch on macOS. Tested 2026-08-30.**
This entry previously predicted the opposite, reasoning that
`kIOFirstMatchNotification` fires on any new matching service and that USB
re-enumerates on wake. A real `pmset sleepnow` / wake cycle produced **zero** log
entries. The premise appears to be wrong on a desktop: the Mac Studio keeps its USB
ports powered through sleep, so the devices are never torn down and no new match
occurs. Do not add edge-tracking to the macOS detector to solve a problem that does
not exist here.

Scope of that result: one cycle, on a desktop with powered USB. A laptop, or a hub
that drops power, could still re-enumerate and fire. Re-test rather than assume if
the hardware changes.

**Sleep/wake does not fire a spurious switch on Windows either. Tested 2026-08-30,
by hibernate (S4)** — see the next entry for why not by S3. The watcher survives
hibernation as a *live process*, so its in-memory `$present` map comes back holding
what it held going down. USB bus power does cycle underneath it — the Focusrite's
relay is audible on the way back — but `Get-PresenceMap` and the restored `$present`
then agree on "present", there is no absent -> present edge, and nothing fires. If
the watcher is restarted across the transition instead, it re-primes at startup and
logs `armed (2 already present, not firing)`. Both paths are safe, and so is the
move in between: flipping the USB switch to this PC *while it is hibernating* does
fire on resume, which is correct — the peripherals really did move here.

**A quiet log is still not proof the edge guard rejected anything — but `-Verbose`
now is.** `event-watch.ps1` used to drop a no-edge device-change event with a bare
`continue` and no line at all, so "no arrival logged" could not distinguish "no
event was delivered" from "an event was delivered and correctly rejected". It now
emits `device-change event yielded no arrival edge (...)` naming whether a watched
device departed or nothing changed. That is `Write-Verbose`, not `Write-Log`: the
OS delivers these constantly and the steady state is noise, so the installed
watcher does not run with `-Verbose` and its log stays quiet. Run the watcher by
hand with `-Verbose` to evidence which case happened.

**`DEVPKEY_Device_LastArrivalDate` does not track this.** It read `03:28:57` (boot)
for both watched devices *both before and after* a hibernate cycle in which bus
power demonstrably cycled. It is not a re-enumeration probe — do not reach for it to
answer "did USB come back?", because it will confidently say no.

**S3 standby HANGS this machine. Do not test it again; use hibernate.**
On 2026-08-30 a sleep entered S3 (power light blinking, displays off) and never
resumed: fans spun back up, no video, no keyboard or mouse, no RDP, hard reboot
required. There is no crash dump and no bugcheck — a hang, not a driver fault, so
there is nothing to attribute and nothing to fix from here.

Nothing in this repo is implicated, and the evidence is worth keeping so the
question does not get reopened: the Scheduled Task is `WakeToRun: False`, the
watcher's last activity was three minutes before the attempt, and user-mode DDC
writes can neither block S3 entry (entry succeeded) nor prevent resume. The System
log holds **zero** `Kernel-Power 42` and **zero** `Power-Troubleshooter 1` events
back to 2026-01-25, so no sleep cycle has ever completed on this machine — this is
not a regression from anything built here.

The cause is platform, not project: `powercfg /a` offers only S3 and Hibernate, and
reports Hybrid Sleep unavailable because "the hypervisor does not support this
standby state", with VBS running under HVCI strict mode. Hibernate is both the safer
and the better test anyway, since S4 drops USB bus power where S3 may not.

Running it from a bash-flavoured shell needs `shutdown -h`, not `shutdown /h`: MSYS
path conversion rewrites the lone `/h` into a Windows path, and `shutdown.exe` prints
its usage instead of doing anything.

**What sleep breaks is the monitors, not the detector — and it is a settings
problem, now closed.** During that same cycle the ASUS defected to the Windows PC
on its own: it lost the Mac's signal while asleep and its auto-input feature moved
it to the other live input. Nothing pulled it back, because **wake is not a
trigger** — the watcher fires on USB arrival, and sleep produces no USB event.

Both monitors have since been tested in both states across real sleep cycles:
enabled, the monitor defects; disabled, it holds. The required OSD settings are in
`displays.toml` and `README.md`. They are named differently per vendor — LG *Auto
Input Switch*, ASUS *Auto Input Detection* — and the ASUS one does cover switching
on signal loss despite the "detection" wording.

**Do not replace this with a wake trigger.** The tempting fix is to re-assert the
displays whenever the machine wakes. The blocking objection is macOS **dark wakes**:
Power Nap, Time Machine and network activity wake the machine constantly without the
user present, and each would re-assert. Guarding on "do I currently hold the
peripherals?" removes some but not all of that. Displays that steal themselves at
random is the worst failure this system can have, and one OSD setting per monitor
prevents the whole class.

Known gap, accepted: neither the setting nor a wake trigger covers drift that
happens while the machine is **awake** — a monitor power-cycle or cable reseat
mid-session still strands you until the USB switch next moves.

**In session 0, `user32` reports ONE PHANTOM MONITOR, not zero. Measured
2026-08-30.** Running `nvapi-probe.ps1` as SYSTEM and as an unelevated S4U task, both
in session 0, `EnumDisplayMonitors` returned **1** monitor in each case, while NVAPI
correctly enumerated both real panels with their real EDIDs.

That phantom is not a real display and is not DDC-capable. The trap is that "no
desktop" does not present as "no monitors" -- it presents as *wrong* monitors, so any
identity check that trusts `user32` in a non-interactive context is matching against
a fiction and will silently mis-resolve. It is also the explanation for the failure
in `haimgel/display-switch` issue #17, where a service using `ddc-hi` logged "Did not
detect any DDC-compatible displays": it found the phantom and got no DDC from it.

Consequence for any future session-0 work: **NVAPI must be the sole source of display
identity, never correlated against the Windows display list.** SimpleKVM's
`BuildDisplayMap` does exactly that correlation and would map nothing here -- do not
lift that structure.

**Do not gate anything on `NV_GPU_DISPLAYIDS.isActive` (flags bit 2).** It read
`False` for both panels at 15:51 and `True` for both at 16:13 **in the same
interactive session**, with no deliberate change in between. So it varies over time
rather than by execution context, and what it actually tracks is not established
here. `isConnected` (bit 6) was stable across every run and every context. Use that.
See `ideas/nvapi-transport.md`.

**Both platforms rotate their log, and macOS must do it by TRUNCATING, not by
renaming.** Windows rotates `%LOCALAPPDATA%\trigger-kvm\trigger-kvm.log` at
startup once it passes `-MaxLogBytes` (default 1MB), keeping one generation as
`.1`, by renaming. macOS keeps the same shape but cannot use a rename: launchd
opens `StandardErrorPath` ONCE, when it starts the job, and the watcher's stderr
IS that descriptor. Renaming would leave it pointing at the renamed inode, so
every line after the first rotation would land in `trigger-kvm.log.1` while the
live log stayed empty -- a rotation that silently swaps which file is the log.
`event-watch.c` copies then `ftruncate`s, which keeps the inode.

Measured 2026-08-31 rather than assumed, because copy-truncate is only correct
if the holder reopens or appends: truncating a file launchd holds open through
`StandardErrorPath` leaves NO NUL hole -- a throwaway agent writing a line a
second, truncated mid-flight, resumed at offset 0 with zero NUL bytes in the
file.

Rotation happens at watcher startup and nowhere else, for two reasons worth not
undoing: it sits *after* the single-instance lock, so a redundant start never
rotates while a watcher is alive; and doing it once per start rather than per
write means the switcher -- a separate process writing to the same file -- can
never race it mid-switch.

**The macOS watcher writes to STDERR ONLY, and `--log` names the file stderr is
already pointed at.** It exists so the watcher knows what to rotate, not as a
second place to write. Writing to both put every line in the log twice, which
the first real install showed immediately. It also matters for ordering: the
switcher the watcher spawns inherits stderr, so one stream keeps an arrival and
the switch it caused in the order they happened.

**An abandoned lock is a WINDOWS condition and has no macOS equivalent. Do not
port the takeover code.** Windows uses a named mutex, which outlives its owner
and throws `AbandonedMutexException` at the next acquirer. macOS uses `flock`,
which the kernel releases when the holding process dies however it dies -- so a
force-killed watcher leaves no lock behind and there is nothing to take over.
There is deliberately no takeover code in `event-watch.c`; adding some would be
solving a problem this platform does not have.

**Both switchers now address exactly one display.** `m1ddc display <uuid> set ...`
always did; the Windows LG path does since 2026-08-30, by aiming the NVAPI I2C
write at the single output whose EDID identifies it. This entry previously said the
macOS side was the safer of the two and that the asymmetry should not be assumed
away — that gap is closed, and the warning it carried is spent.

**The LG's EDID product id is per-input, so it is not a shared constant.** Three
consecutive values have been measured on the one panel — `0x9e9d` (Windows, DP),
`0x9e9f` (Mac, USB-C), `0x9ea0` (Mac, through the old KVM). Each host sees a stable
value for its own input, so it works as a *local* key, but copying one host's value
to another, or treating `displays.toml`'s field as authoritative, will silently
match nothing. Nothing reads it today; this matters if the pre-login path is ever
built. The ASUS reports `0x42e0` everywhere, which makes the trap easy to walk into.

**Running `setup` elevated poisons the task for later unelevated runs.** The task
definition under `System32\Tasks` is owned by whoever registered it, so one run
from an admin shell -- or installing the s4u tier, which requires elevation --
leaves an ordinary user with Read only on their own user-tier task. Every later
unelevated `setup` or `uninstall` then fails with `Access is denied`, after the
scripts have already been copied, which reads like a broken installer rather than a
fixable permission. Both paths detect it and explain; do not "simplify" those catch
blocks away. Recovery is `uninstall` elevated once, then `setup` normally.

## Keep the docs current

Documentation is part of the change, not a follow-up. **In the same commit as the
code**, update whichever of these the change affects:

| File | Update when |
|---|---|
| `README.md` | The front door changes — what it does, install, or the top-level gotchas |
| `ARCHITECTURE.md` | The *shape* changes — components, data flow, a design decision or its rationale. Not for detail churn. |
| `displays.toml` | Any monitor, input value, DDC method, or trigger device changes |
| `macos/README.md`, `windows/README.md` | That platform's install, components, or behaviour changes |
| `AGENTS.md` | A new constraint or hazard is discovered that future work must respect |

Two specific obligations:

- **`displays.toml` is a contract across two independent implementations.** Changing
  a value there means changing every implementation to match, in the same commit.
  A value fixed on one machine and not the other produces a half-switching setup
  that presents as a hardware fault.
- **When a doc's claim stops being true, fix it in that commit.** Stale docs here
  are actively dangerous — this repo's docs encode which values are safe to send to
  a service channel.

New docs earn their existence when their job arises, not before. A spec directory
is not warranted yet; `displays.toml` plus `ARCHITECTURE.md` currently carry the
contract. If the map outgrows a single readable file, graduate it to `specs/`.

## Build and test

```sh
cd macos
make                                      # build event-watch and display-probe
make test                                 # shellcheck + the suite; no hardware needed
make mutate                               # reintroduce each bug the suite should catch
make plist PLIST=/tmp/t.plist             # generate + lint the LaunchAgent, loads nothing
make install                              # build, install, load the agent
make status / make logs / make uninstall

trigger-kvm pull                          # pull configured monitors here
trigger-kvm to pc                         # point them at the computer "pc" (manual)
trigger-kvm pull --only asus              # one monitor only — use when testing
trigger-kvm pull --dry-run                # resolve + print packets, send nothing
trigger-kvm discover / status / restart / logs / pause
```

Both C programs must compile clean under `-Wall -Wextra`. Verify the plist with
`plutil -lint` before claiming an install path works — a malformed plist fails
silently at load.

There is a test suite, and it runs without hardware:

```sh
cd macos && bash tests/run.sh
```

It **cannot move a monitor**: `M1DDC` points at a recorder and `display-probe` at
a fixture, so even a test that drives the whole program through a path nobody
anticipated writes a line to a file instead of a packet to a panel. That is
deliberately stronger than stubbing one function, which is what the Windows suite
does.

The harness runs `set -euo pipefail` and `shellcheck`, because the scripts do —
the same reasoning as `Set-StrictMode -Version Latest` on the other side.

Add to it when you change anything, and then MUTATE the thing you changed and
confirm the new test fails. `tests/mutate.sh` does that mechanically for every
bug the suite is supposed to catch; all of them must be caught.

**An interrupted `mutate.sh` leaves the source MUTATED.** A run killed outright
cannot run its trap, and the next `make` then builds the mutant — which cost an
hour here chasing a single-instance lock bug that did not exist. `tests/run.sh`
refuses to run while a `.mutbak` is present, and `mutate.sh` restores strays on
startup. Do not remove either guard.

To exercise the watcher without installing:

```sh
trigger-kvm pause                         # stand the installed watcher down
./event-watch --exec /bin/echo --arg TEST --device usb:046d:c547 --verbose
trigger-kvm restart                       # restore it afterwards
```

`046d:c547` is the keyboard receiver, which is always present, so this is the
direct check that already-present devices do not fire: it should log
`armed (N already present, not firing)` and **not** fire.

`pause` rather than `kill`, and the difference matters here too: `KeepAlive`
restarts a killed watcher in about a fifth of a second, so killing it is not
standing it down. `pause` unloads the agent; `restart` bootstraps it again.

### Windows

```powershell
cd windows
.\install.ps1                              # install, register the task, start
.\install.ps1 -AddToPath                   # ...and put `trigger-kvm` on PATH
trigger-kvm configure / status / discover / restart / logs / pause / uninstall
trigger-kvm configure -Fresh               # ask everything again, pre-fill nothing
.\trigger-kvm.ps1 pull                 # pull configured monitors to this machine
.\trigger-kvm.ps1 to mac               # point them at the machine "mac" (manual)
.\trigger-kvm.ps1 pull -Only asus      # one monitor only -- use when testing
.\trigger-kvm.ps1 pull -WhatIf         # resolve + print packets, send nothing
```

There is a test suite, and it runs without hardware:

```powershell
cd windows	ests
.
un.ps1
```

Add to it when you change the walkthrough or the menus -- and then MUTATE the thing
you changed and confirm the new test fails. Every regression listed in those files
got there by being shipped once.

**`(Get-Something) -split ';'` needs the parentheses.** Written as
`Get-Something -split ';'`, PowerShell reads `-split` as a PARAMETER of the function,
not as the operator -- a function without `[CmdletBinding()]` swallows it into
`$args` and returns the unsplit string, so the surrounding `-contains` silently never
matches. That shipped, and made `$onPath` permanently false: the walkthrough offered
to add a directory already on PATH, and `status` reported "not on PATH" about a PATH
containing it. The same trap applies to any operator-looking token after a command
name.

**The harness runs `Set-StrictMode -Version Latest`, because the scripts do.** Do not
take it out. Indexing `[0]` into an empty match, reading a property that was never
set, using an undeclared variable -- all of them are quiet under the default mode and
terminating under Latest. A suite that runs without it will pass on code that throws
the moment a user runs it, which is exactly what happened: `@($x | Where-Object
...)[0]` shipped green and died on the first Monitors selection of a fresh install.
Use `| Select-Object -First 1` when a match may be empty.

Both scripts must parse clean before they are run against hardware:

```powershell
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\trigger-kvm.ps1', [ref]$null, [ref]$e)
$e
```

The equivalent watcher smoke test, which fires nothing:

```powershell
trigger-kvm pause                           # stand the installed watcher down
.\event-watch.ps1 -Exec .\some-harmless-script.ps1 -Arg TEST -Device 046d:c547 -Verbose
.\install.ps1                               # restore it afterwards
```

`046d:c547` is the keyboard, which is always present, so this is the direct check
that already-present devices do not fire.

**`pause` rather than `Stop-ScheduledTask`, and the difference has caught people.**
Stopping the task is insufficient twice over: the watcher is a *grandchild* of the
task (task -> `wscript.exe` -> `powershell.exe`), so stopping the task kills only
the shim and leaves the watcher holding the single-instance mutex -- a hand-run one
then exits at once with `another watcher is already running`. And the 1-minute
self-heal trigger would restart it within the minute regardless, so the task has to
be *disabled*, not merely stopped. `pause` does both; `trigger-kvm restart`
re-enables and restarts.

**Shell variables are GLOBAL unless declared `local`, and in `macos/lib/` every
`_`-prefixed name must be.** A callee's loop index otherwise overwrites its
caller's: `select_many`'s `_i` clobbered `wt_check_round`'s, and the monitor
check crashed on an unbound array subscript the first time a batch was narrowed
-- a path no unit test had reached. UPPERCASE names are the deliberate globals;
`_lowercase` is scratch. A variable only READ is fine, and is how a helper reads
its caller's state under bash's dynamic scoping.

No single mutation reproduces this, because with the caller's locals in place a
callee's missing ones are harmless and vice versa. `macos/tests/conventions.tests.sh`
scans for it directly instead, alongside the structural check that `input-alt`
appears exactly once.

## Conventions

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, scoped by
  platform where useful (`feat(macos): ...`).
- Do not hardcode display indices or UUIDs in switching code. Resolve by name at
  runtime — index numbers shift, and index `1` silently becoming the *other*
  monitor would send LG service-channel writes to the ASUS. This is no longer even
  theoretical: on 2026-08-30 the two indices **swapped on this machine**, from
  `DISPLAY1`=ASUS / `DISPLAY2`=LG to `DISPLAY1`=LG / `DISPLAY2`=ASUS, across a hard
  reboot and a hibernate cycle — either could be responsible, they were not
  observed separately. Nothing broke, because the switcher resolves by EDID.
  **Do not write a mapping down anywhere and treat it as stable**, including in
  scratch notes; a stale one is worse than none. The dxva2 description string is no
  help either: it reports the LG as the generic `Generic PnP Monitor`, so neither
  index nor description is a usable key. The switcher matches the EDID manufacturer
  and product that NVAPI reads off the GPU output — the one identity that is stable,
  aimable, and available with no desktop.
- Keep `.ps1` files ASCII-only. Windows PowerShell 5.1 reads a `.ps1` with no BOM
  as ANSI, so a UTF-8 em dash in a comment surfaces as a parse error at an
  unrelated line. Prose files are unaffected; use ASCII punctuation in scripts.
- Send DDC writes more than once. They are idempotent and the bus is lossy.
- **Machine-local facts belong in the generated config, not in the scripts.**
  Since 2026-08-30 the Windows switcher has no hardcoded monitors: which panels are
  here, their EDID ids, their methods and their input values all live in
  `%LOCALAPPDATA%\trigger-kvm\config`. `displays.toml` keeps the *researched,
  cross-machine* knowledge — which methods and VCP codes a given monitor model
  needs, and which values are safe to send it. Do not push discovered, per-desk
  facts back into either the scripts or `displays.toml`.
- **`pull` and `to` are one lookup but two verbs, for a safety reason.** Both read
  the same input map; `pull` asks for `computer.this`, which describes hardware this
  computer is plugged into and can be sure of. Any other name describes inputs on
  hardware it cannot observe. The trigger may only ever run `pull` — never wire
  another computer's name into the trigger path, or a stale one becomes able to cause
  an automatic switch to a dead input.
- **When it starts is a property of the HOST, not the switcher.** All of that logic
  lives in `windows/install.ps1`. Nothing in `trigger-kvm.ps1` or
  `event-watch.ps1` knows or asks when it was started, and if either ever needs
  to, the abstraction is wrong — stop and rethink rather than adding the branch.
  Tiers are mutually exclusive by construction: they share one task name, so
  installing either replaces the other. Two live watchers in different sessions
  would both fire on the same arrival and the debounce is per-process, so it cannot
  dedupe across them. `event-watch.ps1` takes a `Global\` (machine-wide) mutex as
  defence in depth behind that, never a `Local\` one, which is per-session.
- Post-login is the DEFAULT, not the only option, since 2026-08-30. `install.ps1`
  a headless install defaults to login-start; answering "from boot" adds
  before-first-login and
  after-logoff at the cost of admin *to register* (it still runs unelevated). Do not
  change which is the default without asking — no-admin is a deliberate posture.
  macOS remains post-login only, and `trigger-kvm status` SAYS SO rather than
  implying the tiers match: a LaunchDaemon starts before login but runs as ROOT,
  which is not the Windows property (unelevated, as the user, in session 0), and
  the switcher must never run as root to obtain a tier. There would be nothing
  for it to do anyway -- `display-probe` and `m1ddc` both use CoreGraphics,
  which needs a logged-in session.

  The old reasoning against pre-login (session 0 has no `HMONITOR`) was true of the
  `dxva2` path, which no longer exists. Measured 2026-08-30: NVAPI both enumerates
  **and writes** from session 0 — an unelevated S4U task moved the LG in both
  directions with no desktop — and the switcher has no desktop dependency left.
  Note also that **locking is already covered by the user tier**: the session and
  its watcher stay alive, so the displays still follow.
- **Enumerating is not writing. Do not generalise from one to the other.** Phase 1
  proved NVAPI enumerates in session 0 and it was tempting to call pre-login solved;
  it was not, and the write had to be tested separately before anything could be
  claimed. It happened to pass. It could have failed, and the fallback design was
  far more expensive.
- **Never let the switcher trust the Windows display list for identity.** In session
  0 `user32` reports one *phantom* monitor rather than none, so it fails by
  mis-resolving instead of erroring. NVAPI is the sole identity source. This is why
  `dxva2`/`user32` were removed rather than kept as a fallback; see
  `docs/decisions/001-nvapi-as-the-only-windows-transport.md`.
- **Never hand-write NVAPI bindings from memory.** Its dispatch uses magic function
  IDs and size-encoded struct versions; both must come from a real source, and the
  ids in use here are recorded with their provenance in `ideas/nvapi-transport.md`.
  This repo does now bind NVAPI directly rather than wrapping a tool — that was
  earned by sourcing the ids, corroborating them against measured hardware, and
  checking the struct sizes at runtime, not by recalling them.
