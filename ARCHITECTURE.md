# Architecture

## The problem

Two computers share two monitors. The conventional answer is a KVM in the video
path, which failed here: at 5120x2160@165Hz the LG needs DSC over a 25.92 Gbps
HBR3 link, and routing that through a switch plus ~16ft of copper produced
uncorrectable bit errors, visible speckling and link dropouts.

## The approach: pull-to-self

Remove the switch from the video path entirely. Each computer has its own
direct connection to each monitor, and only the USB peripherals move. Whichever
computer receives them tells both monitors, over DDC, to select its own inputs.

| Computer | LG 45GX950A | ASUS PG42UQ |
|---|---|---|
| Mac Studio | USB-C | DisplayPort (via USB-C) |
| Windows PC | DisplayPort | HDMI 1 |

Each computer only ever pulls *toward* itself. Neither pushes the other away,
so there is no coordination protocol, no shared state and no race: only one
computer holds the peripherals at a time, so only one fires. A USB switch mode
that gives the peripherals to both computers at once breaks that premise and is
unsupported.

## The property that makes it work

**A computer's link to a monitor stays enumerated while that monitor displays a
different input.** Both platforms report the display online at full resolution
while the panel shows the other computer, and both accept DDC writes in that
state. Two consequences, both load-bearing:

1. **There is always a DDC path home.** The computer issuing a switch is by
   definition not the one being displayed.
2. **Window layout survives switching.** The OS never sees a disconnect, so it
   never rearranges windows. If only *one* monitor is switched, windows stay on
   a display you can no longer see; that only surfaces during asymmetric testing.

## The precondition: monitors must be passive sinks

The design assumes a monitor changes input **only when commanded**. A monitor
with auto-input detection enabled moves itself to whichever input still carries
a signal as soon as the current one goes quiet, so sleeping either computer
hands its monitors to the other one, and nothing brings them back: the watchers
fire on USB arrival, and sleep produces no USB event.

**Wake is deliberately not a trigger.** Re-asserting on every wake would misfire
on macOS dark wakes (Power Nap, backups, network activity), and displays that
steal themselves at random is the worst failure this system can have. The
remedy is one OSD setting per monitor (`README.md`, `displays.toml`), and its
cost is accepted: a monitor powering on to a signal-less input stays black until
someone reaches its input button. Drift while a computer is awake strands you
until the switch next moves.

## Components

```
displays.toml               researched model knowledge; nothing reads it at run time
specs/                      the contract both implementations are built from
├── check-conformance.sh    the macOS checker for the normative strings
└── config-fixture/         the config reader's shared test cases
macos/
├── event-watch.c           the detector: USB and Bluetooth presence -> execs the switcher
├── display-probe.c         EDID identity + the m1ddc handle, never an index
├── intel-ddc-probe.c       measuring instrument for the Intel route; not built by default
├── trigger-kvm             the one command; dispatches to lib/
├── install.sh              the bootstrap; copies itself alongside the program
└── lib/*.sh                config, display, switch, manage, menu, answers, walkthrough, checks
windows/
├── event-watch.ps1         the detector
├── trigger-kvm.ps1         the switcher: NVAPI I2C or dxva2, per panel
├── config.ps1              the shared vocabulary: config format, verbs, transports
├── nvapi-probe.ps1         read-only display enumeration probe
├── install.ps1             the bootstrap: paths, parameters, and the verb dispatch
└── lib/*.ps1               menu, answers, walkthrough, checks, discover, host
```

Every platform is the same two roles: a **detector** ("do I own the peripherals
now?") and a **switcher** ("make the monitors show me"). They are separate
processes so the switcher stays usable by hand and testable in isolation.

**The detector is one process with N event sources.** Today: USB device
presence and Bluetooth connection. Its contract is `specs/detector.md`. Not one
process per source: the debounce is in-memory, so two watchers would each hold
their own window and both fire when a USB and a Bluetooth device arrive
together. Not "other trigger types just run the command themselves" either:
that makes the user install and supervise a second persistent process. Sources
differ in what constitutes a fire (presence needs debounce and settle; a hotkey
would need neither); they share the process lifetime, the single-instance lock
and the fire. The command interface remains the integration point for anything
not built in: a Stream Deck macro or a scheduled task can run `trigger-kvm pull`.

**A trigger runs `pull`, and only `pull`.** Any other computer's name describes
inputs on hardware this computer cannot observe. Nothing in the trigger path
takes a name at all; `pull` looks up `computer.this`.

On Windows the watcher is a *grandchild* of the scheduled task: the task runs a
generated `wscript.exe` shim (which keeps any console from being allocated), and
the shim runs the watcher. Stopping the task does not stop the watcher, so
`event-watch.ps1` enforces single-instance itself with a named mutex.

## Two kinds of knowledge, two homes

There is no shared code between platforms: macOS reaches DDC through
`IOAVService` (via `m1ddc`), Windows through NVAPI or the Windows DDC/CI stack.
Two kinds of knowledge are kept apart:

- **Researched, cross-machine: `displays.toml`.** Which method a monitor model
  needs, which VCP code carries its input, which values are known safe and which
  have bricked panels. Reference knowledge, not configuration.
- **Discovered, machine-local: the generated config.** Which panels are on this
  desk, their EDID ids, the input value where this computer sits. Flat
  `key = value` so it needs no parser at every device arrival
  (`specs/config-format.md`).

Because each computer only selects its own inputs, two hosts' configs never
have to agree about anything. The only place a config names another computer's
inputs is the same map `pull` uses, reached only by the manual `to <computer>`.

## Dialect and transport

`method` is **what** is sent, `transport` is **how** it gets there.

| Monitor | Dialect | Why |
|---|---|---|
| ASUS PG42UQ | standard DDC/CI, I2C source `0x51`, VCP `0x60` | works normally |
| LG 45GX950A | I2C source `0x50`, VCP `0xF4` (`lg-alt`) | standard input control is stubbed on this panel: writes return success and are ignored |

Address `0x50` is a service channel. Only the values in `displays.toml` are
known safe; sweeping VCP codes there has bricked LG monitors.

Windows has two transports, which makes a 2x2 with one impossible cell:

| | `nvapi` (aimed raw I2C, NVIDIA only) | `dxva2` (Windows' DDC/CI stack, any adapter) |
|---|---|---|
| `standard` | works | works |
| `lg-alt` | works | **impossible**: the stack hardcodes source `0x51`, so adding `dxva2` cannot widen the `0x50` surface |

The impossible pair is refused with the reason named, never downgraded to the
standard command. **A transport is chosen per panel at configure time and is
never a fallback**: the packet that moved the panel on the day somebody watched
it must be the packet sent afterwards. `dxva2` goes through `user32`, which sees
the monitors of the session it runs in, so a `dxva2` panel needs a LOCAL CONSOLE
session: session 0 reports one phantom monitor rather than none, and a Remote
Desktop session reports the RDP virtual display and none of the real panels. A
login tier is necessary and not sufficient, and `configure` and `status` say so.
macOS has one transport, `ioavservice`, and refuses any other name. Decisions
001, 003 and 005 hold the reasoning; readings are in `docs/measurements.md`.

## Identity and the gate

Both switchers address exactly one display, resolved by **EDID vendor and
product** read at that moment. Zero matches is a refusal; more than one is a
refusal too, because an ambiguous target cannot be aimed at, and `list`,
`configure` and `status` each say when an id names more than one attached
panel. One identity key serves both Windows transports: NVAPI reads the EDID off
the GPU output, `dxva2` parses it out of the PnP interface path, and they agree.
Neither an index nor a description string is a usable key: indices have swapped
across a reboot here and GDI names moved across a driver update while the EDID
and NVAPI ids held.

The LG reports a different EDID product id on each of its inputs; the input
decides it, not the host. So the id is a local key that must never be copied
between hosts. The serial is stable across inputs; the derived CoreGraphics UUID
is not.

**The service channel is gated at the transport, not by caller discipline.**
Each platform has exactly one function that can emit source `0x50`
(`ddc_send`, `NvDdc.WriteLgInput`); it takes no source byte and refuses any
target whose EDID manufacturer is not GSM. There is no generic "write to source
N", so no caller, present or future, can aim the sidechannel elsewhere.

## Verification is visual

DDC reads are unreliable on both monitors and have produced false negatives
(`docs/measurements.md`, "DDC reads"). Writes are fire-and-forget, sent twice
because the bus is lossy. A switch is confirmed only by looking at the screen,
which shapes the tooling (no verify-then-retry loops) and the workflow (a human
confirms every behavioural change).

## Debounce and settle

A spurious USB arrival yanks both displays out from under whatever the user is
doing, so the detector treats arrivals as untrusted: **debounce** ignores
arrivals within N seconds of the last fire, and **settle** waits after an
arrival and fires only if the device that arrived is still present. Devices
already present at startup never fire. A single plug produces dozens of events
on Windows, so the debounce is load-bearing.

## When it starts

Both platforms' contract requires **elevation once, to register, and nothing
elevated on the switch path.** Windows boot-token enforcement remains a release
blocker: the 2026-10-30 bounded S4U control ran elevated despite RunLevel Limited
(`docs/measurements.md`).

| | boot | login |
|---|---|---|
| Windows | Scheduled Task, S4U principal, session 0, requests Limited; actual token restriction unresolved; admin once to register | Scheduled Task, interactive |
| macOS | LaunchDaemon with `UserName` set: runs as the user, unelevated, with no session; `sudo` once to install | LaunchAgent |

Windows boot registration runs in an elevated child with the intended user's
identity and paths passed by the parent. Replacing a protected task with login
or no autostart splits the work: the elevated child removes the old task only,
then the original unelevated parent registers the replacement. Its definition
is therefore controllable by that user. The removal child does not install
files, register a task, update configuration or edit PATH (`windows/lib/host.ps1`).

The boot tier covers the login screen after a reboot and the time after a
logoff, both measured on Windows with nobody signed in. Locking is covered by
either tier. On a Mac with FileVault, nothing runs before the pre-boot unlock,
which is also the first login, so the boot tier's gain there is the logged-out
case. A `dxva2` panel cannot follow the switch before login, because session 0
has no desktop -- nor from a Remote Desktop session, which has a desktop with
none of the real monitors in it; on hardware with no NVIDIA card that is the
whole story.

Enumerating and writing from session 0 were proved separately; one does not
imply the other.

**Intel Macs** have no `IOAVService`. The framebuffer I2C route was measured to
reach both panels on both channels and is deliberately not built (decision
004); `intel-ddc-probe.c` is the instrument that proved it.
