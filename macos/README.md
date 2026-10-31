# trigger-kvm on macOS

A watcher (`event-watch`) runs `trigger-kvm pull` when a configured device
arrives; `pull` resolves each configured monitor by the EDID it reads at that
moment and sends it the input-select write over DDC/CI through `m1ddc`. The
shared behaviour is specified in [`../specs/`](../specs/); the safety rules are
in [`../AGENTS.md`](../AGENTS.md).

## Requirements

An Apple Silicon Mac (`m1ddc` does not support Intel Macs), with
[Homebrew](https://brew.sh/) and Apple's command line tools. Install these
prerequisites before running the installer:

```sh
xcode-select --install       # complete the installer dialog before continuing
brew install m1ddc
```

The installer checks both before it builds or copies anything.

## Install

```sh
git clone https://github.com/chrisrishel/trigger-kvm.git
cd trigger-kvm/macos
./install.sh
```

If you already have a checkout, enter its `macos` directory and run
`./install.sh`. Run it as yourself, never with `sudo`; it refuses to run as root.
The only password it asks for installs the "from boot" launchd job, which runs
as you.

The install is self-contained: the installer copies itself next to the program,
so `trigger-kvm uninstall` works after the source tree is gone. To upgrade or
repair, run it again. Only `~/.local/bin/trigger-kvm`, a single symlink, goes on
PATH. Open a new terminal after installation if the command is not found. You
can also run it by its full path: `~/.local/bin/trigger-kvm status`.

| | |
|---|---|
| Config | `~/Library/Application Support/trigger-kvm/config` |
| Log | `~/Library/Logs/trigger-kvm.log` |
| Program | `~/.local/share/trigger-kvm/` |
| Lock | `~/Library/Application Support/trigger-kvm/watcher.lock` |

## Using it

| Command | Purpose |
|---|---|
| `trigger-kvm pull` | point every configured monitor at THIS computer |
| `trigger-kvm to pc` | point them at another computer, by name (manual only) |
| `trigger-kvm pull --only asus` | one monitor only; use when testing |
| `trigger-kvm pull --dry-run` | resolve and print the packets, send nothing |
| `trigger-kvm list` | attached displays, with EDID ids and names |
| `trigger-kvm discover` | what is attached, in the form the config wants |
| `trigger-kvm configure` | the walkthrough; --fresh pre-fills nothing |
| `trigger-kvm status` | is it running, when it starts, the input map |
| `trigger-kvm restart` | make a hand-edited config take effect now |
| `trigger-kvm logs` | tail the log |
| `trigger-kvm pause` | stand the watcher down to test by hand |
| `trigger-kvm uninstall` | remove the program, keeping the config and the log |

The bare command prints the verbs and exits 2. There is no `install` verb and
no `apply` step: display edits take effect on the next switch, trigger edits
when the watcher next starts, which `restart` does.

`pull` and `to` are one lookup, one name apart. `computer.this` names inputs on
hardware this Mac is plugged into; any other name describes inputs it cannot
observe, so the trigger only ever runs `pull`.

## When it starts

| Answer | What is installed | Covers |
|---|---|---|
| From boot | a LaunchDaemon in `/Library/LaunchDaemons` with `UserName` set, so it runs as you, unelevated; `sudo` once to install it | from boot onward, including the login screen and after logout. With FileVault, from the pre-boot unlock, which is also your login |
| From login | a LaunchAgent in `~/Library/LaunchAgents` | from login onward, including while the screen is locked |
| No | the same agent plist, kept in the program directory and loaded now | this session only; `restart` loads it again |

The tiers are mutually exclusive: choosing one removes the others. If "from
boot" cannot be installed (no password, or launchd refuses the job) it falls
back to login, says so, and the config records login. `status` says which tier
is installed and what it covers, and `restart` reports whether anything came up.
If the existing boot job cannot be stopped or removed, changing to another
tier fails with an explanation; rerun `configure` to finish the change.

## The walkthrough and the checks

`trigger-kvm configure` is one menu: name the computers, say which computer is
on which input of each monitor, tick the devices that travel with the switch,
choose when it starts, test the inputs and the trigger while you watch, then
save. Escape discards changes in the submenu you leave. Configuration is written
only on Save. The contract is
[`../specs/configure.md`](../specs/configure.md); what is specific to this
platform:

- All menus scroll to keep the highlighted entry and its details visible.
  Home/End selects the first/last entry (including Done); Page Up/Down moves
  by a visible page. A range indicator shows where you are in a long list.
  Resizing reflows the menu on the next keypress without losing checked devices.
  If an entry and the controls cannot fit, the menu explains and uses numbered
  input. Current choices remain the default; `q` goes back where Escape is
  available. Use terminal scrollback to read the numbered list.
- Standard DDC/CI is the default for every panel. The LG dialect is offered for
  LG panels, and only values from [`../displays.toml`](../displays.toml) or
  values you type are ever sent on it.
- A monitor check sends the panels in scope away and back and asks once; one
  panel always stays on this computer. The transport-only check made when no
  other computer is configured, and a retry of one panel, go through the same
  warning. The trigger check pulls for real only while every managed, attached
  panel holds a current pass; an edit to a map or method retires it.
- The trigger check restores a login or session watcher it successfully paused,
  including on EOF or cancellation. A watcher already paused stays paused. The
  boot watcher remains running, and the check says so.
- A configured monitor that is not attached today is shown as such, kept on
  Save, and not checked. Only unmanaging forgets it.
- A trigger entry saved with a `@token@where` suffix stays selected and is
  written back as saved while its device is away.

## Configuration

A flat `key = value` file, specified in
[`../specs/config-format.md`](../specs/config-format.md). It is machine-local:
`computer.this` differs per machine, and the LG reports a different EDID
product id per input (`0x9E9F` on this Mac's USB-C, `0x9E9D` on the Windows
PC's DisplayPort), so an id copied from another host matches nothing. Read ids
with `trigger-kvm list`.

Two devices of one model share a vendor:product id. Where that matters the
walkthrough writes `usb:VVVV:PPPP@token@where` and `status` says how the
current saved configuration resolves it ([`../specs/detector.md`](../specs/detector.md)
4.1). This does not read a running watcher's loaded settings; trigger edits
require `trigger-kvm restart`. Two attached monitors of one model are one
identity; the switch refuses it, and `list`, `configure` and `status` say so.

## Components

```
trigger-kvm         the one command; dispatches to lib/
lib/common.sh       paths, logging, text helpers
lib/config.sh       the config reader and writer
lib/display.sh      resolve a panel by EDID; ddc_send, the one place a packet leaves
lib/switch.sh       list, discover, pull, to, set
lib/manage.sh       watch, launchd and the tiers, restart, pause, logs, status
lib/menu.sh         the two menus and their typed fallback
lib/answers.sh      the walkthrough's state: tables, the per-panel map, load, write
lib/walkthrough.sh  the walkthrough's flow
lib/checks.sh       the monitor and trigger checks
display-probe.c     every attached display: EDID vendor, product, serial, name, m1ddc UUID
event-watch.c       the watcher, and the one owner of "is that device here?"
intel-ddc-probe.c   a measuring instrument for the Intel-Mac route; not built by default
install.sh          build, copy, apply the tier
```

**`display-probe`** joins CoreGraphics (identity and the UUID `m1ddc` takes)
with IOKit (the panel's own name from EDID descriptor `0xFC`) on
vendor+product+serial, and prints one row per online external display.

**`event-watch`** is one process with two sources: USB through IOKit first-match
notifications on `IOUSBHostDevice`, Bluetooth by polling
`system_profiler SPBluetoothDataType -xml`, and only when a `bt:` device is
configured. Bluetooth presence means connected; the candidate list offers every
paired device. An arrival is debounced (`trigger.debounce`, default 3 s) and
settled (`trigger.settle`, default 0.75 s): it fires only if the device that
arrived is still there. Devices present at startup never fire.

```
event-watch --exec PATH [--arg pull] --device usb:VVVV:PPPP[@token[@where]]|bt:AAAAAAAAAAAA ...
            [--debounce S] [--settle S] [--log PATH] [--max-log-bytes N] [--verbose]
event-watch --list                   what could be a trigger, as kind|key|state|name|role|token|where
event-watch --report --device ...    how each entry resolves now: key|present|absent|where|ambiguous
event-watch --lock-status            is a watcher running, from the lock
event-watch --test-trigger --device ... [--timeout S]   report ONE arrival and exit, running nothing
```

Single instance is a `flock` on the lock file, released by the kernel when the
holder dies, so there is no abandoned-lock case. A watcher that cannot take the
lock for any reason other than "held" refuses to start. The log rotates at
startup, after the lock, by copy-then-truncate, because launchd holds
`StandardErrorPath` open and the watcher writes to stderr only.

## Running a watcher by hand

```sh
trigger-kvm pause                          # stand the installed one down; never kill it
./event-watch --exec /bin/echo --arg TEST --device usb:046d:0843 --verbose
trigger-kvm restart                        # put the installed one back
```

`pause` reports a watcher that is still running rather than claiming it paused.
Two fixtures replace the hardware for the suite and are useful by hand:
`TK_USB_LIST=<file>` names `vendor|product|name|where|role` rows the watcher
polls in place of IOKit, and `TK_BT_PLIST=<file>` a plist in
`system_profiler`'s shape in place of Bluetooth.

## Testing

```sh
make test        # shellcheck + the suite; no hardware needed
make mutate      # reintroduce each bug the suite should catch
```

The suite cannot move a monitor or reach launchd: `M1DDC` points at a recorder,
`TK_PROBE` at a fixture, every `launchctl` goes through `$TK_LAUNCHCTL` (a
recorder that can also refuse), and the watcher reads the two fixtures above.
The walkthrough and the checks are driven end to end through the menus' typed
fallback; the real key reader is driven through a pty. A test that did not run
reports `SKIP` and never counts as a pass. `tests/conventions.tests.sh` scans
for the rules no single mutation can test: one door to source `0x50` in shell
and in C, one door into launchd, `local` scratch variables, no assertion inside
a piped loop, one config-line writer, no function defined twice, and the
instruction-file byte budget.
