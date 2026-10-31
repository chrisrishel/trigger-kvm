# trigger-kvm

**Flip a USB switch and the monitors follow. No KVM in the video path.**

Two or more computers share the same monitors. Each computer is cabled directly
to every monitor, on its own input. A USB switch moves the keyboard, mouse and
whatever else you share. When those devices arrive at a computer, it commands
each monitor over DDC/CI to select that computer's input. The video cables stay
connected. Link renegotiation and window layout still depend on the monitor,
adapter and operating system; the LG on the reference desk flickers during each
input change.

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
```

Developed and tested against one desk: an LG 45GX950A, an ASUS PG42UQ, one Mac
and one Windows PC. Anything else is untested, and the maintainers cannot test
hardware they do not own. Read [Safety](#safety) before you run it.

## What it needs

| | macOS | Windows |
|---|---|---|
| Computer | Apple Silicon (`m1ddc`, the DDC tool used, does not support Intel Macs) | Any GPU for a monitor that takes the standard DDC/CI command. An **NVIDIA** GPU for a monitor that needs a manufacturer's own method (the LG here does), and for any monitor that must follow the switch at the login screen |
| Software | Homebrew `m1ddc`; Xcode command line tools | Windows PowerShell 5.1, as shipped |
| Permissions | None. "Start from boot" asks for your password once to install a system launchd job that then runs as you | None for "start from login". "Start from boot" requests administrator approval; standard-user registration and boot-process token restriction remain [release blockers](windows/RELEASE-CHECKS.md) |
| Triggers | USB devices, and Bluetooth devices that connect | USB devices, and Bluetooth devices that connect |

**Monitors.** Each must accept input selection over DDC/CI. Support varies by
model. A few ignore the standard command and only answer their manufacturer's
own method;
one such method is supported, LG's, and it is offered for LG panels only,
because it uses a service channel that must never be sent to another make. A
monitor that answers neither is unsupported, and the setup walkthrough says so
rather than guessing.

**Cabling.** Every computer needs its own cable to every monitor, each on a
different input. The USB switch must hand the peripherals to one computer at a
time; a switch mode that gives them to both is unsupported.

**A trigger.** Something that *arrives* at a computer when you switch: a USB
device that enumerates on connection, or a Bluetooth device that reconnects. A
device wired directly to one computer cannot be a trigger. A webcam is a good
one; audio interfaces can re-enumerate on their own and are weaker.

The other computer's operating system does not matter to this one. Each runs
its own copy; automatic triggers select only its own inputs. Manual commands
can select another configured computer.

## Before you install

1. **Turn off automatic input switching on every monitor.** Vendors name it
   differently (*Auto Input Switch*, *Auto Input Detection*, *Auto Source*) and
   it is usually on. With it on, a monitor jumps to the other computer the
   moment this one sleeps, and nothing brings it back until you next flip the
   switch. No software compensates for this.
2. **Cable every computer to every monitor**, and note which input each is on.
   The walkthrough asks.

## Install

Obtain the source on each computer with Git, then follow the platform's
prerequisites and installation steps: [macOS](macos/README.md#requirements) or
[Windows](windows/README.md). Run these commands in Terminal on macOS, or in
Windows PowerShell on Windows:

```sh
git clone https://github.com/chrisrishel/trigger-kvm.git
cd trigger-kvm
```

If you download a source ZIP instead, extract it and open a terminal in the
extracted directory. The installer builds or copies the program and opens the
walkthrough when no configuration exists. After installation, open a new
terminal if the command is not yet on PATH.

```sh
cd macos && ./install.sh            # macOS
```

```powershell
cd windows; .\install.ps1           # Windows
```

The walkthrough is one menu: name the computers, say which computer is on
which input of each monitor, tick the devices that travel with the switch,
choose when it starts, optionally test the inputs and the trigger while you
watch, then save. Configuration is written only on Save. With multiple monitors,
each test keeps one here so you can read the question. With one monitor, the
walkthrough warns you before switching it and explains how to restore its input
manually. The full contract is [`specs/configure.md`](specs/configure.md).

Long menus scroll with the highlight on both platforms. Home/End jumps to the
first/last entry; Page Up/Down moves by a visible page. A small window uses
numbered input when it cannot fit an entry and its controls. Scrolling and resizing preserve
the current selection and checked items (specification revision 16).

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

| Command | Purpose |
|---|---|
| `trigger-kvm` | the verbs, with a line each; exits 2 |
| `trigger-kvm pull` | point every configured monitor at THIS computer |
| `trigger-kvm to <computer>` | point them at another computer, by name. Manual only |
| `trigger-kvm pull --only main` | one monitor only; use when testing (works with to as well) |
| `trigger-kvm pull --dry-run` | resolve and print the packets, send nothing |
| `trigger-kvm list` | connected displays, with their identifiers |
| `trigger-kvm discover` | what is attached, in the form the config wants |
| `trigger-kvm configure` | change any of it (the same walkthrough) |
| `trigger-kvm configure --fresh` | open the walkthrough without pre-filled answers |
| `trigger-kvm status` | is it running, when it starts, what that covers |
| `trigger-kvm logs` | tail the log |
| `trigger-kvm restart` | make a hand-edited config take effect now |
| `trigger-kvm pause` | stand the watcher down; restart brings it back |
| `trigger-kvm uninstall` | remove the program, keeping the config and the log |

There is no `install` verb: installing is what produced the command. To upgrade
or repair, fetch the source and run its installer again.

`trigger-kvm status` also shows the installed product version, specification
revision and source commit when available. A clone starts on the development
branch; select a release tag before installing if you want a released build.
The version string alone does not identify development changes. Both platforms
share one product version; see [versioning and releases](CONTRIBUTING.md#versioning-and-releases).

`to <computer>` is manual only. It names inputs on hardware this computer
cannot see, so a stale name can spoil a command you typed and are watching,
never an automatic switch. A trigger only ever runs `pull`. The config behind
both verbs is one map:

```
computer.this = desktop
display.main.input.0x11 = desktop       # which computer is on which input
display.main.input.0x0f = laptop
trigger.device = usb:046d:0843, bt:0011223344ff
```

## Safety

You use this at your own risk. It writes to your monitors' control channels.

- **A switch cannot be verified in software.** Monitors return wrong values
  when read back; both of the ones this was developed against do. The tool
  never reads a value to decide anything, and the walkthrough asks you to look
  at the screen instead.
- **A manufacturer's method uses a service channel.** The one supported, LG's,
  is I2C address `0x50`. Only values from documentation, or a value you type,
  are ever sent to it, never a sweep or a guess. An LG monitor has been bricked
  by sweeping that channel (ddcutil issue #419, "Bricked LG Monitor"). Do not
  experiment there. The code refuses to send on that channel to any monitor
  whose EDID vendor is not LG.
- **Your last display is never taken silently.** Every check names which
  monitor stays before it moves the others, and the one-monitor case tells you
  how to get back before it starts. Blind value-walking is refused outright
  when it would take the only display.
- Use `--only` / `-Only` when testing by hand, so the monitor your terminal is
  on stays put.

## When it does not work

| Symptom | Cause and fix |
|---|---|
| A monitor jumps to the other computer when this one sleeps | Its automatic input switching is still on. Turn it off in the monitor's menu. |
| A monitor shows black or "No Signal" after power-on | With automatic input switching off, a monitor that powers on to an input with no signal stays there. Use its input button. This is the cost of the setting above. |
| A monitor flickers on every switch, even to the input it is already on | Normal (the LG here does it). It is renegotiating the link, and each write is sent twice on purpose. |
| Only one device appears in the log per flip | Normal. Watched devices arrive together; the first fires and the second is absorbed. A second `pull` for one flip is harmless. |
| Switching does nothing | `trigger-kvm status` says whether a watcher is running and what it covers; `trigger-kvm logs` says what it saw. Then `trigger-kvm pull` by hand: if that moves the monitors, the trigger is wrong; if not, the inputs are. Both are re-checked with `trigger-kvm configure`. |
| You moved a cable to a different input, or copied a config from another computer | Run `trigger-kvm configure` again. Some panels report a different EDID product id per input (the LG here does), so an id measured elsewhere matches nothing. |
| Two monitors of the same model | They read as one identity, and rather than guess the tool refuses both and says so in `list`, `configure` and `status`. Unplug one. Telling them apart is designed, not built. |
| It does not switch at the login screen after a reboot | Only *from boot* covers the login screen and the time after a logoff; both settings cover a locked screen. Change it with `trigger-kvm configure`. On a Mac with FileVault, "from boot" begins at the FileVault unlock, which is also your login. |
| Windows: `status` shows a last-run result of `0x800710E0` | Normal while the watcher is healthy: a repeating task trigger restarts a dead watcher within a minute, and that code is Task Scheduler noting one was already running. |

## How it works

Each computer runs one background watcher and one switcher. The watcher listens
for a configured device to go from absent to present, waits a moment to confirm
it is still there, and runs `trigger-kvm pull`. The switcher resolves each
configured monitor by the EDID vendor and product it reads at that moment,
never by an index, and sends the input-select write, twice, to that one output.
A computer only ever pulls monitors toward itself, so there is no shared state
and nothing to coordinate. The design rests on one measured property: a
computer's link to a monitor stays enumerated while the monitor displays another
input, so there is always a path to command it back. The reasoning is in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Repository layout

| Path | What it is |
|---|---|
| [`macos/`](macos/README.md), [`windows/`](windows/README.md) | The two implementations. Same verbs, same config, same walkthrough; no shared code. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The design and why it is shaped this way |
| [`specs/`](specs/README.md) | What both implementations are built from: the config format, the walkthrough, the detector, `status` |
| [`ROADMAP.md`](ROADMAP.md) | What is built, what is next, what is deliberately not |
| [`displays.toml`](displays.toml) | Reference values for the two monitors this was developed against |
| [`docs/`](docs/) | Decision records and the dated hardware measurements the rules rest on |
| [`AGENTS.md`](AGENTS.md) | Instructions for anyone changing this repo, including AI agents: the safety rules and the order a change to shared behaviour lands in |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Contributing, versioning and releases, and useful monitor and bug reports |

## Related work

[haimgel/display-switch](https://github.com/haimgel/display-switch) is the
established tool in this space: it switches monitor inputs over standard DDC/CI
when a USB device connects or disconnects, on macOS, Windows and Linux, from an
INI file you write.

| | display-switch | trigger-kvm |
|---|---|---|
| Monitors it can drive | those that take the standard DDC/CI input command | the same, plus a manufacturer channel for panels that ignore it (LG today), gated to that vendor |
| Setup | a hand-edited INI file | a walkthrough that reads your monitors' EDID, asks which computer is on which input, and offers to prove it by moving one monitor at a time while you watch |
| Direction | switches on connect, and optionally the other way on disconnect | pull only: the computer that receives the devices takes the monitors |
| Before login | no | yes, on both platforms, without anything running elevated |
| Triggers | USB | USB, and a Bluetooth device connecting |
| Platforms | macOS, Windows (any GPU), Linux | macOS (Apple Silicon), Windows (any GPU for standard panels; NVIDIA for a manufacturer channel, or wherever there is no local console session -- before login, or over Remote Desktop) |

If you want Linux, display-switch is the better fit.

[SzozdaK/DDC-Trigger](https://github.com/SzozdaK/DDC-Trigger) is the same idea
with a Raspberry Pi as the DDC console and an industrial USB switch as the
trigger. This project runs on the computers themselves, with no extra hardware.

## License

MIT, see [`LICENSE`](LICENSE). Third-party notices are in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
