# Architecture

## The problem

Two machines share two monitors. The conventional answer is a KVM in the video
path, which failed here: at 5120×2160@165Hz the LG needs DSC over a 25.92 Gbps
HBR3 link, and routing that through a switch plus ~16ft of copper produced
uncorrectable bit errors, visible speckling, and link dropouts.

## The approach: pull-to-self

Remove the switch from the video path entirely. Give **each machine its own direct
connection to each monitor**, and move only the USB peripherals. Whichever machine
receives the peripherals tells both monitors, over DDC, to select its own inputs.

```
             ┌── USB-C ──────────────┐
Mac Studio ──┤                       ├── LG 45GX950A   (USB-C | DisplayPort)
             └── USB-C→DP ───────┐   │
                                 ├───┼── ASUS PG42UQ   (DisplayPort | HDMI 1)
Windows PC ──── DisplayPort ─────┘   │
           └─── HDMI 1 ──────────────┘

USB switch ──> peripherals ──> arriving machine pulls both displays to itself
```

Each machine only ever pulls *toward* itself. Neither pushes the other away, so
there is no coordination protocol, no shared state, and no race: only one machine
holds the peripherals at a time, so only one fires.

## The property that makes it work

**A host's link to a monitor stays enumerated while that monitor displays a
different input.** macOS continues to report the display as online at full
resolution even when the panel is showing the other machine. Windows behaves the
same way — both monitors stay in `EnumDisplayMonitors` with full desktop rects
while showing the Mac, and both accept DDC writes in that state. Confirmed
independently on both platforms, so the property is a monitor behaviour rather than
an OS quirk either side happens to have.

Two consequences, and both are load-bearing:

1. **There is always a DDC path home.** The machine issuing a switch command is by
   definition not the one being displayed. If the link dropped when deselected,
   pull-to-self would be impossible and the design would collapse to push-only.
2. **Window layout survives switching.** The OS never sees a disconnect, so it
   never rearranges windows. This is the main day-to-day win over the KVM, which
   dropped the link and caused macOS to pile windows onto the remaining display.

The second point has a corollary worth knowing: if only *one* monitor is switched,
windows stay on a display you can no longer see. In normal operation both move
together, so this only surfaces during asymmetric testing.

## The precondition: monitors must be passive sinks

The design assumes a monitor changes input **only when commanded**. A monitor with
vendor auto-input-detection enabled does not honour that — it moves itself to
whichever input still carries a signal as soon as the current one goes quiet.

Sleeping a machine makes its signal go quiet. So with the feature on, sleeping
either machine hands its monitors to the other one, and nothing brings them back:
the watchers fire on USB arrival, and sleep produces no USB event. **Wake is
deliberately not a trigger** — re-asserting on every wake would misfire on macOS
dark wakes (Power Nap, backups, network activity), and displays that steal
themselves at random is the worst failure this system can have.

Verified on both monitors in both states across real sleep cycles: enabled, they
defect; disabled, they hold. The required settings are in `README.md` and
`displays.toml`; they are named differently by each vendor.

This is an **environment precondition, not a software concern**. No amount of code
compensates for a monitor that switches itself, and attempting to compensate would
mean re-asserting on a timer or on wake — both worse than setting one OSD option
per monitor, once.

Its cost is real and accepted: auto-detection doubles as a recovery mechanism, so
with it off, a monitor powering on to a signal-less input stays black until someone
reaches the joystick.

## Components

```
displays.toml          researched model knowledge — shared by both platforms
├── macos/
│   ├── event-watch.c     watches for events →  execs the switcher
│   ├── display-probe.c   EDID + m1ddc handle → identity, never an index
│   ├── trigger-kvm       the one command    →  every verb
│   ├── install.sh        the bootstrap; copies itself alongside the program
│   └── lib/*.sh          config, display, menus, walkthrough, checks
└── windows/
    ├── event-watch.ps1   watches for events →  execs the switcher
    ├── trigger-kvm.ps1   aimed NVAPI I2C, both panels → sends the DDC writes
    ├── nvapi-probe.ps1   read-only display enumeration probe (diagnostic)
    └── install.ps1       the walkthrough, discovery, task registration
```

On Windows the watcher is a *grandchild* of the scheduled task — the task runs a
generated `wscript.exe` shim, which is what keeps any console from being allocated,
and the shim runs the watcher. Stopping the task therefore does not stop the
watcher, so `event-watch.ps1` enforces single-instance itself with a named mutex.
`windows/README.md` covers the reasoning.

Every platform implementation is the same two roles: **a detector** and **a
switcher**. The detector answers "do I own the peripherals now?"; the switcher
answers "make the monitors show me." They are separate processes so the switcher
stays usable by hand and testable in isolation.

The detector is **one process with N event sources**, not one process per source.
Today it has two — USB device presence and Bluetooth connection — and the shape is
deliberate, because the obvious alternative is wrong in two different ways. Its
contract is [`specs/detector.md`](specs/detector.md).

*Not* a second watcher process per source: the debounce is in-memory, so two
watchers would each hold their own window and both fire when a USB device and a
Bluetooth device arrive together. That is the double-fire the machine-wide mutex
exists to prevent, and the mutex would in fact stop the second watcher starting.

*Not* "other trigger types just run the command themselves" either. That is true
architecturally and a poor answer practically: it makes the user install and
supervise a **second persistent background process** — AutoHotkey, or similar — to
do a job the process we already run could do. Every extra always-running thing is
another install step and another way for the setup to end up half working. A hotkey
belongs in here, configured in the same file as everything else.

Sources differ in what constitutes a fire, and that is a per-source concern rather
than a reason to split:

| Source | Fires on | Needs debounce/settle |
|---|---|---|
| device presence | an absent → present **edge** | yes — a spurious arrival would yank the displays |
| hotkey | a keypress | no — deliberate and discrete |

What all sources share is the process lifetime, the single-instance lock, and the
fire itself. That is what makes them one process.

The **command interface remains** the integration point for anything not
implemented here — a Stream Deck macro, a remote script, a scheduled task can all
run `trigger-kvm pull` and always could. It stops being the *only* answer for things
a user would reasonably expect built in.

One rule holds across every source: **a trigger runs `pull`, and only `pull`.** Any
other computer's name describes inputs on hardware this machine cannot observe, so a
stale one must never be reachable from anything automatic. Nothing in the trigger
path takes a name at all — `pull` looks up `computer.this` — which is why that holds
by construction rather than by discipline.

macOS is built this way: `event-watch.c` runs a `CFRunLoop` with an
`IONotificationPort` source for USB, a poll timer for Bluetooth and a settle
timer multiplexed. (Bluetooth is polled through `system_profiler` rather than
subscribed through IOBluetooth, for a permission reason recorded in
`macos/AGENTS.md`.) A hotkey would be another `CFRunLoopAddSource`, in the same
process, by design.

## Two kinds of knowledge, two homes

There is no shared code between platforms. macOS reaches DDC through
`IOAVService`; Windows reaches it through NVAPI. No runtime, no language, no
library in common. But there are two *kinds* of knowledge here, and conflating them
was costing more than it saved.

**Researched, cross-machine — `displays.toml`.** Which method a monitor model needs,
which VCP code carries its input, which values are known safe, which are known to
brick. That an LG 45GX950A has its input on I2C source `0x50`/VCP `0xF4` because
standard `0x60` is stubbed is true of that model *everywhere*, and expensive to
rediscover. This is reference knowledge, not configuration.

**Discovered, machine-local — the generated config.** Which panels are on *this*
desk, their EDID ids, and the input value where *this* machine sits. Generated by
the installer into `%LOCALAPPDATA%\trigger-kvm\config` (Windows), hand-editable, and
read at every switch.

The reframing that made this clean: **each machine only ever selects its own
inputs.** The switcher pulls displays toward itself and holds no belief about any
other machine, so two hosts' configs don't have to agree about anything — a change
on one cannot invalidate the other. `displays.toml`'s old role as a *contract*
between implementations dissolves with that; what remains genuinely shared is
model knowledge, which is reference data, and nothing reads the file at run time.
The one place a config names inputs belonging to another computer is the same
map `pull` uses (`display.<label>.input.<value> = <computer>`), reached only by
the manual `to <computer>` — the trigger can never get there.

Neither file is parsed by a heavyweight reader at runtime. The generated config is
flat `key = value` precisely because it is read on every device arrival and must not
depend on a TOML or JSON parser being installed.

## Why two different DDC dialects

The two monitors do not speak the same dialect:

| Monitor | Dialect | Why |
|---|---|---|
| ASUS PG42UQ | Standard DDC/CI, I2C source `0x51`, VCP `0x60` | Works normally |
| LG 45GX950A | I2C source `0x50`, VCP `0xF4` | Standard input control is **stubbed** on this panel |

Two dialects, but no longer two code paths. macOS reaches both through `m1ddc`
(`set input` vs `set input-alt`).

## Dialect and transport are two axes, not one

**`method` is WHAT is sent** — which VCP dialect, and therefore which values are
legal. **`transport` is HOW it gets there** — which driver API carries the bytes.
They were one key while every platform had exactly one transport. Windows now has
two, which makes a 2×2 with one impossible cell:

| | `nvapi` — aimed raw I2C, NVIDIA only | `dxva2` — Windows' own DDC/CI stack, any adapter |
|---|---|---|
| `standard` (`0x51`, VCP `0x60`) | works | works |
| `lg-alt` (`0x50`, VCP `0xF4`) | works | **impossible** |

The impossible cell is a *safety property*, not merely a limitation: the Windows
DDC/CI stack hardcodes I2C source `0x51` and `SetVCPFeature` takes a VCP code
rather than an address, so **adding `dxva2` cannot widen the `0x50` surface at
all.** That is asserted by the conventions scan rather than remembered. The pair
is refused with the reason named, never quietly downgraded to the standard
command — somebody who asked for a sidechannel, silently got something else, and
then confirmed by eye that a panel moved would be wrong about what moved it.

**A transport is chosen per panel at configure time and is never a fallback.**
Nothing tries one and falls through to the other at switch time, because the
packet that moved the panel on the day somebody watched it must be the packet
sent afterwards — a human eye is the only verification this hardware permits.
`configure` offers the choice only where a panel enumerated on more than one
transport; enumerating adapters and reading EDIDs sends nothing to a monitor, so
that offer is not the probing `AGENTS.md` 1b forbids.

**What `dxva2` costs is stated where it is chosen.** It goes through `user32`,
which in session 0 reports one phantom monitor rather than none — it would fail
by mis-resolving. So a `dxva2` panel is login-tier only: `configure` draws the
`From boot` row disabled naming the panel, an already-chosen boot tier falls back
to login and says so, and `status` reports which panel a transport strands. This
is the whole story on hardware with no NVIDIA card, and it is accepted as a
property of such a panel rather than a defect to fix later.

Why there are two, and why the objection in
`docs/decisions/001-nvapi-as-the-only-windows-transport.md` was answered by a
change in circumstances rather than by argument:
`docs/decisions/003-dxva2-as-a-second-windows-transport.md`. Readings in
`docs/measurements.md`.

The LG accepts `VCP 0x60` writes, returns success, and discards them; reads always
return `0x0F` regardless of what is displayed. Recent LG monitors moved input
control to a manufacturer sidechannel ("DDC2AB"). This is not a workaround for a
bug — it is the only functioning interface on that hardware.

Address `0x50` is a service channel. Only the values in `displays.toml` are known
safe; sweeping VCP codes there has bricked LG monitors.

## Both switchers aim at exactly one display

`m1ddc display <uuid> set ...` addresses one display by UUID. The Windows switcher
addresses one display by **EDID identity**: it enumerates the connected outputs,
reads each one's EDID, and writes only to the single output whose manufacturer and
product id identify the intended panel. Both monitors are resolved that way, and
each write reaches one output.

**One identity key serves both transports**, which is what lets the transport be
a per-panel choice rather than a second notion of what a monitor is: NVAPI reads
the EDID off the GPU output, `dxva2` parses it out of the PnP interface path, and
the two agree exactly. The *whole* interface path is not the key and never was —
moving a cable changed the path while the EDID id inside it held, which is
precisely what broke the earlier matcher.

The safety rule that matters — a `0x50` service-channel write must never reach a
non-LG panel — is enforced at the transport rather than by the caller.
`NvDdc.WriteLgInput` is the only function that can emit source `0x50`; the source
byte is not one of its parameters, and it refuses any target whose EDID
manufacturer is not GSM. Making the unsafe call unrepresentable is the point: there
is no code path, and no future caller, that can aim the sidechannel elsewhere.

The switch also fails closed on ambiguity. Zero matching outputs is a refusal, and
so is more than one, because a target that cannot be resolved to a single output
cannot be aimed at. That refusal is correct but was invisible until revision 13,
which is a separate property: `list`, `configure` and `status` now each say when
an id names more than one attached panel, so the condition is met where something
can be done about it rather than in a log after a monitor stops following.

**This replaced a genuinely dangerous arrangement, and the shape of the current
design is a direct response to it.** Until 2026-08-30 the LG was driven by
`lg-input-switch`, which loops over every connected output mask and ports 0–7 and
sends the packet to all of them, never identifying the LG. Switching the LG
therefore delivered a service-channel write to every other monitor on the GPU. A
guard compensated by refusing whenever an unrecognised panel was attached, which
made "plug in a third monitor" a way to silently stop LG switching. Aiming the write
removes the hazard and the guard together, and the third monitor stops mattering.

## Verification is visual, by necessity

DDC reads are unreliable on both monitors and produced false negatives during
development — the ASUS returns `0` for everything including `max luminance`, and
the LG returns `-7` while its link is inactive or renegotiating. Both monitors
switched correctly while reads said they had not.

Writes are fire-and-forget. **A switch is only confirmed by looking at the screen.**
No automated verification is possible with this hardware, which shapes both the
tooling (no verify-then-retry loops) and the workflow (a human confirms every
behavioural change).

## Robustness: debounce and settle

A spurious USB arrival yanks both displays out from under whatever the user is
doing. This desk has a documented history of USB instability, so the detector
treats arrivals as untrusted:

- **debounce** — ignore arrivals within N seconds of the last fire; stops two
  watched devices arriving together from double-firing, and stops a flapping device
  from thrashing the displays.
- **settle** — after an arrival, wait, then confirm the device is *still* present.
  Appear-then-vanish was a glitch, not a switch.

Devices already present at startup never fire.

## Scope: both platforms can start before login

Both offer the same two tiers, and both hold the same property: **elevation once,
to register, and nothing elevated on the switch path.**

| | boot | login |
|---|---|---|
| Windows | Scheduled Task, S4U principal, session 0, unelevated | Scheduled Task, Interactive |
| macOS | LaunchDaemon with `UserName` set — as the user, unelevated, no session | LaunchAgent |

**On macOS this section used to say the boot tier was impossible**, because
`m1ddc` links CoreGraphics and `CGGetOnlineDisplayList` supposedly needs a window
server connection a daemon has not got. That was reasoning, not measurement, and
it was wrong. Measured 2026-08-31 from a LaunchDaemon with no session:

- IOKit display identity works with **no CoreGraphics at all** — both panels
  found by EDID vendor, product and name.
- `m1ddc display list` works, returning both panels and their UUIDs.
- A full `trigger-kvm pull` works **as uid 501, not root**, with both writes sent.

So the tier costs one plist and a single `sudo` at install. `UserName` is what
makes it the Windows tier rather than a root daemon: launchd drops privileges
before running the job. A root daemon acting on a user-writable config would be a
local privilege escalation, and is not what this is.

**On Windows the desktop dependency is gone.** This section used to argue that
session 0 blocked Windows too, because it has no desktop and therefore no
`HMONITOR` — true of the `dxva2` path, which is why that path no longer exists,
and re-measured directly on 2026-09-01: there `user32` offers one phantom monitor
with no EDID identity and `dxva2` refuses it a handle outright. It
also predicted NVAPI would fail "for the same reason". That prediction was wrong:
measured 2026-08-30, NVAPI enumerates and identifies both panels from session 0, as
SYSTEM and as an unelevated S4U task, and again from an at-startup task after a cold
boot. Both monitors are now driven over NVAPI, so `windows/trigger-kvm.ps1`
touches no desktop API at all.

The trap that finding exposed: in session 0 `user32` reports **one phantom monitor,
not zero**. "No desktop" presents as *wrong* monitors rather than none, so any
identity check that trusts the Windows display list in a non-interactive context
matches against a fiction. NVAPI is therefore the sole identity source. See
`windows/AGENTS.md`.

The Windows side is still a Scheduled Task at logon in the interactive session, but
that is now a **choice about permissions, not a technical limit**. Measured
2026-08-30: an unelevated S4U task in session 0, with no desktop, drove the LG to
the Mac and back — confirmed visually. Enumeration and writing both work there, and
they had to be established separately: enumeration working did not imply writing
would.

What remains is the permission trade, which is real and is the user's to make:

- **Registering a pre-login task needs admin.** S4U registration is denied to a
  standard user, and the password logon type is rejected because it means storing a
  credential. So no-admin genuinely buys post-login only — a capability ladder
  rather than an oversight.
- **Locking is already covered without any of this.** Confirmed 2026-08-30: with the
  screen locked, flipping the USB switch still pulls the displays back, because the
  session and its watcher are still alive. Starting from boot therefore buys the two
  narrower cases: **before the first login after a boot**, and **after a full
  logoff**. The first is the one that stings — a rebooted PC sitting at a login
  screen you cannot see, because the monitors are still showing the other machine.

  **The logoff case is now measured, not argued.** On 2026-09-02, between a
  logoff and the next logon — no interactive session on the machine at all — the
  session-0 watcher fired and pulled **both** displays back from the Mac to the
  PC, confirmed by eye, on a round trip that also saw both go to the Mac in the
  first place. Until then every session-0 result had been taken with a user still
  logged on, which made this the last provisional claim in the pre-login path.

See `ideas/nvapi-transport.md`.

A CoreGraphics-free macOS transport — `IOAVServiceCreateWithService` +
`IOAVServiceWriteI2C` against IORegistry entries — is no longer needed for the
boot tier, since `m1ddc` works without a session. It remains the route if the
`m1ddc` dependency is ever worth dropping. The identity half is already solved
and shipped: `display-probe` matches on **EDID vendor and product read from
IORegistry**, never on order, so the concern that order-based pairing could send
the LG's `0xF4` to the ASUS does not apply. The symbol names are real, read from
the installed binary: `IOAVServiceCreate`, `IOAVServiceCreateWithService`,
`IOAVServiceReadI2C`, `IOAVServiceWriteI2C`. Their signatures would still need a
real source — never memory.

**Intel Macs have no `IOAVService`, and the route they do have is proven but not
built.** The framebuffer I2C interface (`IOFBCopyI2CInterfaceForBus` +
`IOI2CSendRequest`) was measured on 2026-09-01 to reach both panels on both
channels in both directions, including the LG's service channel. It is not
implemented, and `README.md` still says Apple Silicon because that is what is
supported. The decision, the seams it would touch and everything the measurement
learned are in `docs/decisions/004-intel-mac-ddc-proven-not-built.md`; the
readings are in `docs/measurements.md`. The shape it would take matters here:
the arch would pick the *tool* on one line of `ddc_send`, never the *policy*, so
the single service-channel gate does not move.

**Do not key that on the EDID product ID without checking it first.** The LG reports
a *different product ID on every input* — four consecutive values have been
measured on this one panel, one per path (see `displays.toml`). The input decides
the value, not the host: two different Macs plugged into the same input read the
same ID. So it is usable as a local key, but it is meaningless as a shared
constant and must never be copied between hosts. The ASUS does not behave this
way, which makes it easy to assume the field is stable when it is not.
