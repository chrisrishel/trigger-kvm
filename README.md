# trigger-kvm

**Connect your devices. Your monitors follow.**

trigger-kvm switches your monitors to a computer when a USB or Bluetooth device
you choose connects to it. Each computer connects directly to the monitors, so
video doesn't need to pass through a KVM.

You can plug in a USB device, connect a hub or dock carrying a selected USB
peripheral, or use a Bluetooth device that reconnects when you change computers.
A USB switch is one convenient way to move several peripherals together.

Example setup with a USB switch:

```text
              ┌───────────┐
Computer A ───┤ input 1   │
              │  Monitor  │
Computer B ───┤ input 2   │
              └───────────┘

Computer A ═╗
            ╠═ USB switch ═ peripherals
Computer B ═╝
```

## Will it work with my setup?

You need a supported USB or Bluetooth device to act as a trigger, a separate
video cable from each computer to each monitor, and monitors that accept input
changes over **DDC/CI** (monitor control over the video cable). Setup lists the
devices trigger-kvm can watch.

| Platform | Requirements |
|---|---|
| macOS | Apple Silicon, Homebrew `m1ddc`, and Xcode command line tools. Intel Macs are not supported. |
| Windows | 64-bit Windows 10 or 11, Windows PowerShell 5.1, and Windows Script Host with VBScript enabled. |

On Windows, **NVIDIA is required for the supported LG manufacturer method and
switching before login**. Other GPUs can use standard DDC/CI through `dxva2`,
selected during setup, while you are logged in at the computer; that method
does not work over Remote Desktop. See the [Windows guide](windows/README.md#requirements).

Physical testing covers one desk: an Apple Silicon Mac, a Windows 11 PC with
an RTX 4090, an LG 45GX950A and an ASUS PG42UQ. Other monitors, adapters and
Windows versions are unverified. Monitors that report the same identity cannot
be managed together. Linux is not supported.

## Before you install

1. **Turn off automatic input switching on each monitor.** Otherwise it may
   jump to another computer when one sleeps. Enable DDC/CI if the monitor has
   a setting for it.
2. Connect every computer to every monitor and note which input each uses.
   Install and configure trigger-kvm separately on each computer.
3. Read the [safety notes](#safety). Setup can test a monitor by switching it
   away and back; keep the terminal on a monitor that stays visible.

## Install

Get the source with Git:

```sh
git clone https://github.com/chrisrishel/trigger-kvm.git
cd trigger-kvm
```

This checks out the development branch. For a released build, choose a
[release tag](https://github.com/chrisrishel/trigger-kvm/tags) and run
`git checkout vX.Y.Z`, replacing `vX.Y.Z` with that tag, **before installing**.
You can also download a tag's source ZIP and extract it instead of using Git.

### macOS

Install [Homebrew](https://brew.sh/) first. In Terminal, install any missing
prerequisites; finish the command line tools dialog before continuing:

```sh
xcode-select --install
brew install m1ddc
```

From the source directory:

```sh
cd macos
./install.sh
```

Run as yourself, without `sudo`. The installer requests a password if you
choose to start from boot. [macOS details](macos/README.md)

### Windows

Open **Windows PowerShell** as your normal user, without “Run as administrator.”
From the source directory:

```powershell
cd windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath
```

The execution-policy option applies only to this process. Starting from boot
requests administrator approval; a standard account may also need its own
account password. Choose login if that is unavailable. For blocked downloads,
organization policies and permissions, see the [Windows guide](windows/README.md#install).

### Set it up

On first installation, the walkthrough asks you to name your computers, map
each monitor's inputs to those names, and choose the devices whose connection
should bring the monitors to this computer. Select devices that connect when
you want to use that computer; a device that stays connected won't signal a
change. Use the offered checks to confirm the input mapping by looking at the
screens, then **Save**.

Choose **From boot** to cover the login screen where supported, **From login**
to start when you sign in, or **No** to run only for this session. On a Mac
with FileVault, boot coverage begins after disk unlock. The watcher runs with
ordinary user privileges in every mode.

Open a new terminal after installation, then run `trigger-kvm status`. Long
setup menus scroll as you move the highlight; Page Up/Down and Home/End help
with large lists. Run `trigger-kvm configure` whenever your setup changes.

## Everyday use

Connect or reconnect a selected device to the computer you want to use. That
computer selects its own monitor inputs automatically. With a USB switch,
pressing its button moves the devices and triggers the change.

Triggers respond to new connections. A device already connected when the
watcher starts doesn't trigger a switch. Neither does activity on a device
that stays connected, Bluetooth pairing alone, or waking the computer.

| Command | Use it to… |
|---|---|
| `trigger-kvm status` | Check the watcher, startup mode and saved configuration. |
| `trigger-kvm configure` | Change computers, monitor inputs, triggers or startup mode. |
| `trigger-kvm pull` | Manually bring all configured monitors to this computer. |
| `trigger-kvm pause` | Pause automatic switching. |
| `trigger-kvm restart` | Resume switching or reload edited trigger settings. |
| `trigger-kvm logs` | Follow the diagnostic log. |
| `trigger-kvm uninstall` | Remove the program, keeping configuration and logs. |

To upgrade, obtain the desired release and run its installer again; your saved
configuration is retained. `status` shows the installed version and source
commit when available. Editing source files does not update an installed copy.

For manual switching to another computer, one-monitor commands, dry runs and
file locations, use the [macOS](macos/README.md#using-it) or
[Windows](windows/README.md#using-it) command reference. Each computer keeps its
own configuration; do not copy a monitor map from one computer to another.

## Safety

This software writes to your monitors' control channels. Use it at your own risk.

- **Confirm input changes by eye.** A successful command does not prove the
  screen changed. Monitor read-back is unreliable and is not used to verify a switch.
- **Keep a working display.** When testing manually, target one monitor with
  `--only` on macOS or `-Only` on Windows, and keep the terminal on another.
  With only one monitor, know how to restore its input using the monitor's controls.
- **Do not guess manufacturer commands.** The supported LG method uses a
  service channel; experimenting with such commands can damage a monitor.
  Setup offers known methods for matching panels. Use only documented values
  from [the reference list](displays.toml) or values you know are correct for
  your monitor.

## Troubleshooting

| Problem | What to check |
|---|---|
| Connecting a selected device doesn't switch the monitors | Run `status` and `logs`, then use the checks in `configure` to review your trigger and input map. |
| A monitor switches by itself when a computer sleeps | Turn off the monitor's automatic input selection. Waking a computer is not a trigger. |
| A monitor shows no signal after power-on | Select the active input with the monitor's controls; automatic input selection is disabled. |
| A monitor briefly blanks or flickers when switching | The video link may reconnect during an input change. This is expected on the reference LG. |
| Switching stops working after moving a cable | Run `configure` again; monitor identity can depend on the connected input. |
| The command is not found | Open a new terminal and check the platform guide's PATH instructions. |

For help, [report a bug](CONTRIBUTING.md#reporting-a-bug) or
[share a monitor report](CONTRIBUTING.md#reporting-a-monitor-that-is-not-one-of-the-two).
Remove personal paths, device names, serials and other identifiers from logs,
configuration and screenshots before sharing them.

## Learn more

- [macOS guide](macos/README.md) · [Windows guide](windows/README.md)
- [0.3.0 release notes](docs/releases/0.3.0.md) · [Roadmap](ROADMAP.md)
- [Design](ARCHITECTURE.md) · [Specifications](specs/README.md) · [Hardware evidence](docs/measurements.md)
- [Contributing and versioning](CONTRIBUTING.md) · [Publication privacy](docs/privacy.md)

Related projects: [display-switch](https://github.com/haimgel/display-switch)
(including Linux support) and [DDC-Trigger](https://github.com/SzozdaK/DDC-Trigger)
(a Raspberry Pi approach).

## License

[MIT](LICENSE). See [third-party notices](THIRD-PARTY-NOTICES.md).
