# trigger-kvm

**Flip a USB switch and the monitors follow. No KVM in the video path.**

Two or more computers share the same monitors. Each computer is cabled directly
to every monitor, on its own input. A USB switch moves the keyboard, mouse and
whatever else you share. When those devices arrive at a computer, it commands each
monitor over DDC/CI to select that computer's input. Nothing switches video, so
the link never drops and your window layout survives every switch.

```
                    ┌────────────────────┐
  Computer A ───────┤ input 1            │
                    │         Monitor 1  │
  Computer B ───────┤ input 2            │
                    └────────────────────┘
                    ┌────────────────────┐
  Computer A ───────┤ input 1            │
                    │         Monitor 2  │
  Computer B ───────┤ input 2            │
                    └────────────────────┘

  Computer A ═══╗
                ╠═══ USB switch ═══ keyboard, mouse, webcam, ...
  Computer B ═══╝

  Flip the switch. The computer that receives the devices tells every monitor,
  over DDC/CI, to show its own input. Video cables never move.
```

Developed and tested against one desk: two monitors (an LG 45GX950A and an ASUS
PG42UQ), one Mac and one Windows PC. Anything else is untested, and the
maintainers cannot test hardware they do not own. Read [Safety](#safety) before
you run it.

## Does it apply to your hardware?

**Monitors.** Each monitor must accept input selection over DDC/CI. Most do.
Some ignore the standard command and only answer their manufacturer's own
method; one such method is supported today, LG's, and it is offered for LG
panels only, because it uses a service channel that must never be sent to
another make. A monitor that answers neither is unsupported, and the setup
walkthrough tells you so rather than guessing.

**Cabling.** Every computer needs its own cable to every monitor, each on a
different input.

**A trigger.** Something that *arrives* at a computer when you switch: a USB
switch carrying at least one device that enumerates on connection, or a
Bluetooth device that reconnects. A device wired directly to one computer
cannot be a trigger.

| | macOS | Windows |
|---|---|---|
| Hardware | Apple Silicon. `m1ddc`, the DDC tool used, does not support Intel Macs. | Any GPU, for a panel that takes the standard DDC/CI command -- but such a panel only follows the switch once somebody has logged in. An **NVIDIA GPU** for a panel needing a manufacturer sidechannel (the LG here does), and for any panel that must switch at the login screen. |
| Software | Homebrew `m1ddc` (`brew install m1ddc`); Xcode command line tools (`xcode-select --install`) | Windows PowerShell 5.1, as shipped. Nothing to install. |
| Permissions | None. Choosing "start from boot" asks for your password once, to install a system launchd job that then runs as you. | None for "start from login". Choosing "start from boot" raises one UAC prompt to register the task, which then runs as you; your account must itself be an administrator for that option. |
| Bluetooth triggers | Yes. No permission prompt is involved. | Yes. |

The other computer's operating system does not matter to this one. Each
computer runs its own copy and only ever selects its own inputs.

## Before you install

1. **Turn off automatic input switching on every monitor.** Every vendor names
   it differently -- *Auto Input Switch*, *Auto Input Detection*, *Auto Source*
   -- and it is usually on by default. With it on, a monitor jumps to the other
   computer the moment this one sleeps, and nothing brings it back until you
   next flip the switch. Nothing in software compensates for this.
2. **Cable every computer to every monitor**, and note which input each is on.
   The walkthrough asks.
3. **Decide what goes through the USB switch.** A webcam is a good trigger: it
   enumerates when connected and rarely otherwise. Audio interfaces can
   re-enumerate on their own and are weaker. You pick the devices from a list
   during setup.

## Install

Run the installer on each computer, from a checkout of this repository. It
builds or copies what it needs, then -- when there is no configuration yet --
starts the setup walkthrough itself. There is nothing to run afterwards.

```sh
cd macos && ./install.sh            # macOS
```

```powershell
cd windows; .\install.ps1           # Windows
```

The walkthrough is one menu. Finishing a section returns you to it with the
cursor on the next thing that needs an answer:

1. **Computers** -- name this one and the others. The names are what you type to
   switch by hand (`trigger-kvm to desktop`).
2. **Monitors** -- each attached monitor reports its own name. For each, say
   which computer is on which input. Where the manufacturer has a documented
   alternative to standard DDC/CI, you are offered it here, with what it means.
3. **Triggers** -- a checklist of the USB devices attached and the Bluetooth
   devices paired right now. Tick what travels with the switch.
4. **Autostart?** -- from boot, from login, or not at all.
5. **Add to PATH?** -- one directory holding one launcher.
6. **Test the monitor inputs** (optional) -- moves the monitors to each computer
   for about eight seconds, brings them back, and asks what you saw. One monitor
   always stays on this computer so you can read the question, and it is named
   before anything moves. With a single monitor you are told how to get back
   with the monitor's own input button before anything is sent, and can decline.
7. **Test the triggers** (optional) -- flip the switch away and back. Once the
   inputs have passed, that flip pulls the monitors for real: the whole thing
   working, before anything is saved.
8. **Save** -- nothing is written until here. Cancel, or an interrupted run,
   leaves an existing setup untouched.

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
trigger-kvm pull --only main     one monitor only -- use when testing (works with `to` as well)
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
computer.this = desktop
display.main.input.0x11 = desktop       which computer is on which input
display.main.input.0x0f = laptop
trigger.device = usb:046d:0843, bt:0011223344ff
```

## Safety

You use this at your own risk. It writes to your monitors' control channels.

- **A switch cannot be verified in software.** Monitors return wrong values
  when read back -- both of the ones this was developed against do, and they
  are not unusual. The tool never reads a value to decide anything, and the
  walkthrough asks you to look at the screen instead.
- **A manufacturer's method uses a service channel.** The one supported today,
  LG's, is I2C address `0x50`. Only values from documentation, or a value you
  type, are ever sent to it -- never a sweep or a guess. An LG monitor has been
  bricked by sweeping that channel (ddcutil issue #419, "Bricked LG Monitor").
  Do not experiment there, and do not type a value onto it that you did not get
  from documentation. The code refuses to send on that channel to any monitor
  whose EDID vendor is not LG.
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

**A monitor flickers on every switch, even to the input it is already on.**
Normal (the LG here does it). It is renegotiating the link, and each write is
sent twice on purpose.

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
EDID product id per input (the LG here does), so an id measured on one input, or
on another computer, matches nothing on this one.

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
| [`ROADMAP.md`](ROADMAP.md) | Where this has been and where it is going: what is built, what is next, what is deferred and why |
| [`displays.toml`](displays.toml) | Reference values for the two monitors this was developed against: methods, input codes, known-safe values |
| [`docs/`](docs/) | Decision records and the dated hardware measurements the rules rest on |
| [`AGENTS.md`](AGENTS.md) | Instructions for anyone changing this repo, including AI agents: the safety rules for the monitors' control channels and the order a change to shared behaviour lands in. Read it before contributing. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute, and what a useful report about a monitor nobody here has met contains |

## Related work

[haimgel/display-switch](https://github.com/haimgel/display-switch) is the
established tool in this space: it switches monitor inputs over standard DDC/CI
when a USB device connects or disconnects, on macOS, Windows and Linux, from an
INI file you write. The differences, so you can pick:

| | display-switch | trigger-kvm |
|---|---|---|
| Monitors it can drive | those that take the standard DDC/CI input command | the same, plus a manufacturer channel for panels that ignore it (LG today), gated to that vendor |
| Setup | a hand-edited INI file | a walkthrough that reads your monitors' EDID, asks which computer is on which input, then proves it by moving one monitor at a time while you watch |
| Direction | switches on connect, and optionally the other way on disconnect | pull only: the computer that receives the devices takes the monitors. Nothing is ever pushed toward a computer that cannot see the result |
| Before login | no | yes, on both platforms, without anything running elevated |
| Triggers | USB | USB, and a Bluetooth device connecting |
| Platforms | macOS, Windows (any GPU), Linux | macOS (Apple Silicon), Windows (NVIDIA only) |

If your monitors all take the standard command and you want Linux or a
non-NVIDIA Windows computer, display-switch is the better fit.

[SzozdaK/DDC-Trigger](https://github.com/SzozdaK/DDC-Trigger) is the same idea
with a Raspberry Pi as the DDC console and an industrial USB switch as the
trigger. This project runs on the computers themselves, with no extra hardware.

## License

MIT — see [`LICENSE`](LICENSE). Third-party notices are in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
