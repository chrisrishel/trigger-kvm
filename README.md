# trigger-kvm

**Flip a USB switch and the monitors follow. No KVM in the video path.**

Two or more computers share the same monitors. Each computer is cabled directly
to every monitor, on its own input. A USB switch moves the keyboard, mouse and
whatever else you share. When those devices arrive at a computer, it commands each
monitor over DDC/CI to select that computer's input. Nothing switches video, so
the link never drops and your window layout survives every switch.

```
             ┌── USB-C ──────────────┐
Mac ─────────┤                       ├── LG 45GX950A   (USB-C | DisplayPort)
             └── USB-C→DP ───────┐   │
                                 ├───┼── ASUS PG42UQ   (DisplayPort | HDMI 1)
Windows PC ──── DisplayPort ─────┘   │
           └─── HDMI 1 ──────────────┘

USB switch ──> peripherals ──> whichever computer gets them pulls the monitors to itself
```

Developed and tested against exactly this: an LG 45GX950A and an ASUS PG42UQ,
from one Mac and one Windows PC. Anything else is untested, and the maintainers
cannot test hardware they do not own. Read [Safety](#safety) before you run it.

## Does it apply to your hardware?

**Monitors.** Each monitor must accept input selection over DDC/CI. Most do.
Some LG models ignore the standard command and only answer LG's own method; that
method is supported, for LG panels only. A monitor that answers neither is
unsupported, and the setup walkthrough tells you so rather than guessing.

**Cabling.** Every computer needs its own cable to every monitor, each on a
different input.

**A trigger.** Something that *arrives* at a computer when you switch: a USB
switch carrying at least one device that enumerates on connection, or a
Bluetooth device that reconnects. A device wired directly to one computer
cannot be a trigger.

| | macOS | Windows |
|---|---|---|
| Hardware | Apple Silicon. `m1ddc`, the DDC tool used, does not support Intel Macs. | An **NVIDIA GPU**. DDC is sent through NVAPI, the only transport; AMD and Intel GPUs are unsupported. |
| Software | Homebrew `m1ddc` (`brew install m1ddc`); Xcode command line tools (`xcode-select --install`) | Windows PowerShell 5.1, as shipped. Nothing to install. |
| Permissions | None. Choosing "start from boot" asks for your password once, to install a system launchd job that then runs as you. | None for "start from login". Choosing "start from boot" raises one UAC prompt to register the task, which then runs as you; your account must itself be an administrator for that option. |
| Bluetooth triggers | Yes. No permission prompt is involved. | Yes. |

The other computer's operating system does not matter to this one. Each
computer runs its own copy and only ever selects its own inputs.

## Before you install

1. **Turn off automatic input switching on every monitor.** The setting has a
   different name per vendor -- *Auto Input Switch* on the LG, *Auto Input
   Detection* on the ASUS. With it on, a monitor jumps to the other computer the
   moment this one sleeps, and nothing brings it back until you next flip the
   switch. Nothing in software compensates for this.
2. **Cable every computer to every monitor**, and note which input each is on.
   The walkthrough asks.
3. **Decide what goes through the USB switch.** A webcam is a good trigger: it
   enumerates when connected and rarely otherwise. Audio interfaces can
   re-enumerate on their own and are weaker. You pick the devices from a list
   during setup.

## Install

Run the installer on each computer, from a checkout of this repository. It
builds or copies what it needs, then starts the setup walkthrough.

```sh
cd macos && ./install.sh            # macOS
```

```powershell
cd windows; .\install.ps1           # Windows  (add -AddToPath to put trigger-kvm on PATH)
```

The walkthrough is one menu: **Computers** (named once; the names are what you
type to switch by hand), **Monitors** (each reports its own name; you say which
computer is on which input, and where the manufacturer has a documented
alternative to standard DDC/CI you are offered it up front), **Triggers** (a
checklist of what is attached or paired right now), **Autostart?** (from boot,
from login, or no), **Add to PATH?**, then two optional checks, then Save.
**Nothing is written until you choose Save**; Cancel or an interrupted run
leaves an existing setup untouched.

**Test the monitor inputs** moves the monitors to each computer for about eight
seconds, brings them back, and asks what you saw. One monitor always stays on
this computer so you can read the question, and the walkthrough names it before
anything moves. With a single monitor it tells you how to get back with the
monitor's own input button before it sends anything, and lets you decline.
**Test the triggers** asks you to flip the switch away and back; once the inputs
have passed, that flip pulls the monitors for real.

Where things land:

| | macOS | Windows |
|---|---|---|
| Config | `~/Library/Application Support/trigger-kvm/config` | `%LOCALAPPDATA%\trigger-kvm\config` |
| Log | `~/Library/Logs/trigger-kvm.log` | `%LOCALAPPDATA%\trigger-kvm\trigger-kvm.log` |
| Program | `~/.local/share/trigger-kvm/` | `%LOCALAPPDATA%\Programs\trigger-kvm\` |
| On PATH | `~/.local/bin/trigger-kvm` (one symlink) | `%LOCALAPPDATA%\Programs\trigger-kvm\bin\` (one `.cmd`) |

The config is a flat `key = value` file, safe to edit by hand; display edits
apply on the next switch, trigger edits after `trigger-kvm restart`.
Uninstalling keeps the config and the log. Platform detail:
[`macos/README.md`](macos/README.md), [`windows/README.md`](windows/README.md).

## Using it

Normally you do nothing: flipping the switch runs `pull` on the computer that
receives the devices. The verbs are the same on both platforms; flags follow
each platform's convention (`--only` / `-Only`, `--dry-run` / `-WhatIf`,
`--fresh` / `-Fresh`).

```
trigger-kvm pull                 point every configured monitor at THIS computer
trigger-kvm to <computer>        point them at another computer, by name. Manual only
trigger-kvm pull --only lg       one monitor only -- use when testing
trigger-kvm pull --dry-run       resolve and print the packets, send nothing
trigger-kvm list                 connected displays, with their identifiers
trigger-kvm discover             what is attached, in the form the config wants
trigger-kvm configure            change any of it (the same walkthrough)
trigger-kvm configure --fresh    ...pre-filling nothing
trigger-kvm status               is it running, when it starts, what that covers
trigger-kvm logs                 tail the log
trigger-kvm restart              make a hand-edited config take effect now
trigger-kvm pause                stand the watcher down; restart brings it back
trigger-kvm uninstall            remove the program, keeping the config and the log
```

There is no `install` verb: installing is what produced the command. To upgrade
or repair, fetch the source and run its installer again.

`to <computer>` is manual only. It names inputs on hardware this computer
cannot see, so a stale name can spoil a command you typed and are watching,
never an automatic switch. A trigger only ever runs `pull`. The config behind
both verbs is one map:

```
computer.this = pc
display.lg.input.0xD0 = pc          which computer is on which input
display.lg.input.0xD1 = mac
trigger.device = usb:046d:0843, bt:0011223344ff
```

## Safety

You use this at your own risk. It writes to your monitors' control channels.

- **A switch cannot be verified in software.** Both monitors this was developed
  against return wrong values when read back. The tool never reads a value to
  decide anything, and the walkthrough asks you to look at the screen instead.
- **LG's input method uses a service channel** (I2C address `0x50`). Only
  values from documentation, or a value you type, are ever sent to it -- never a
  sweep or a guess. An LG monitor has been bricked by sweeping that channel
  (ddcutil issue #419, "Bricked LG Monitor"). Do not experiment there, and do
  not type a value onto it that you did not get from documentation. The code
  refuses to send on that channel to any monitor whose EDID vendor is not LG.
- **Your last display is never taken silently.** Every check names which
  monitor stays before it moves the others, and the one-monitor case tells you
  how to get back before it starts. Blind value-walking is refused outright when
  it would take the only display.
- Use `--only` / `-Only` when testing by hand, so the monitor your terminal is
  on stays put.

## When it does not work

**A monitor jumps to the other computer when this one sleeps.** Its automatic
input switching is still on. Turn it off in the monitor's menu.

**A monitor shows black or "No Signal" after power-on.** With automatic input
switching off, a monitor that powers on to an input with no signal stays there.
Use the input or source button on the monitor. This is the cost of the setting
above.

**The LG flickers on every switch, even to the input it is already on.** Normal.
It is renegotiating the link, and each write is sent twice on purpose.

**Usually only one device appears in the log per flip.** Normal. Watched devices
arrive together; the first fires, the second lands inside the debounce window.
If the second arrives later than that window, `pull` runs a second time, which
is harmless.

**Switching does nothing.** Run `trigger-kvm status` (is a watcher running,
what does it cover) and `trigger-kvm logs`. Then `trigger-kvm pull` by hand:
if that moves the monitors, the trigger is wrong; if not, the inputs are. Both
are re-checked with `trigger-kvm configure`.

**You moved a cable to a different input, or copied a config from another
computer.** Run `trigger-kvm configure` again. Some panels report a different
EDID product id per input -- the LG 45GX950A does -- so an id measured on one
input, or on another host, matches nothing here.

**Windows: `status` shows a last-run result of `0x800710E0`.** Normal while the
watcher is healthy. A repeating task trigger restarts a dead watcher within a
minute; that code is Task Scheduler noting one was already running.

**It does not switch at the login screen after a reboot.** Autostart is *from
login*. Switching works while the screen is locked on either setting; only
*from boot* covers the login screen and the time after a logoff. Change it with
`trigger-kvm configure` (admin once on Windows; your password once on macOS,
where the boot tier also makes `restart` and `pause` ask for it).

## How it works

Each computer runs one background watcher and one switcher. The watcher listens
for a configured device to go from absent to present, waits a moment to confirm
it is still there, and runs `trigger-kvm pull`. The switcher resolves each
configured monitor by the EDID vendor and product it reads at that moment, never
by an index, and sends the input-select write, twice, to that one output. A
computer only ever pulls monitors toward itself, so there is no shared state and
nothing to coordinate. The design rests on one measured property: a computer's
link to a monitor stays enumerated while the monitor displays another input, so
there is always a path to command it back. The reasoning is in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Repository layout

| Path | What it is |
|---|---|
| [`macos/`](macos/README.md), [`windows/`](windows/README.md) | The two implementations. Same verbs, same config, same walkthrough; no shared code. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The design and why it is shaped this way |
| [`specs/`](specs/README.md) | What both implementations are built from: the config format and the walkthrough |
| [`displays.toml`](displays.toml) | Reference values for the two monitors this was developed against: methods, input codes, known-safe values |
| [`docs/`](docs/) | Decision records and the dated hardware measurements the rules rest on |
| [`AGENTS.md`](AGENTS.md) | Instructions for anyone changing this repo, including AI agents: the safety rules for the monitors' control channels and the order a change to shared behaviour lands in. Read it before contributing. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute, and what a useful report about a monitor nobody here has met contains |

## Related work

- [haimgel/display-switch](https://github.com/haimgel/display-switch) -- switches
  monitor inputs over DDC/CI when a USB device connects; macOS, Windows and
  Linux. This project adds LG's manufacturer method for panels that ignore
  standard input control, per-output aiming on Windows, and a start-from-boot
  option; it does not support Linux.
- [SzozdaK/DDC-Trigger](https://github.com/SzozdaK/DDC-Trigger) -- the same idea
  with a Raspberry Pi as the DDC console and an industrial USB switch as the
  trigger. This project runs on the computers themselves, with no extra hardware.

## License

MIT — see [`LICENSE`](LICENSE). Third-party notices are in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
