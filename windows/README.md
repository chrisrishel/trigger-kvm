# trigger-kvm on Windows

A watcher (`event-watch.ps1`) runs `trigger-kvm pull` when a configured device
arrives; `pull` resolves each configured monitor by the EDID it reads at that
moment and sends it the input-select write over DDC/CI. The shared behaviour is
specified in [`../specs/`](../specs/); the safety rules are in
[`../AGENTS.md`](../AGENTS.md) and this platform's hazards in
[`AGENTS.md`](AGENTS.md).

## Requirements

Windows 10 or 11 and stock Windows PowerShell 5.1 -- no modules, no downloads,
no third-party binary. An NVIDIA GPU for the `nvapi` transport, which is the one
that works before anyone logs in; without one, panels are driven through
`dxva2`, which needs a desktop.

## Install

```powershell
cd windows
.\install.ps1                  copy files, register the task, start it
.\install.ps1 -AddToPath       ...and put `trigger-kvm` on PATH
```

With no config yet it runs the walkthrough first. It asks for administrator
rights ONCE, and only if you choose "from boot"; nothing runs elevated on the
switch path afterwards.

The install is self-contained: the installer copies itself next to the program,
so uninstalling works after the source tree is gone. To upgrade or repair, run
it again. Only `bin\`, which holds a single `trigger-kvm.cmd`, goes on PATH.

| | |
|---|---|
| Config | `%LOCALAPPDATA%\trigger-kvm\config` |
| Log | `%LOCALAPPDATA%\trigger-kvm\trigger-kvm.log` |
| Program | `%LOCALAPPDATA%\Programs\trigger-kvm\` |
| Task | `trigger-kvm`, in the root Task Scheduler folder |
| Lock | a `Global\` named mutex, held by the running watcher |

## Using it

```powershell
trigger-kvm pull                 point every configured monitor at THIS computer
trigger-kvm to mac               point them at another computer, by name (manual only)
trigger-kvm list                 attached displays, with EDID ids and names
trigger-kvm configure            the walkthrough; -Fresh pre-fills nothing
trigger-kvm status               is it running, when it starts, the input map
trigger-kvm discover             what is attached, in the form the config wants
trigger-kvm restart              make a hand-edited config take effect now
trigger-kvm logs                 tail the log
trigger-kvm pause                stand the watcher down to test by hand
trigger-kvm uninstall            remove the program, keeping the config and the log
```

Two flags matter when you are testing, and both are the switcher's:

```powershell
.\trigger-kvm.ps1 pull -Only asus     one monitor only
.\trigger-kvm.ps1 pull -WhatIf        resolve and print the packets, send nothing
```

The bare command prints the verbs and exits 2. There is no `install` verb and no
`apply` step: display edits take effect on the next switch, trigger edits when
the watcher next starts, which `restart` does.

`pull` and `to` are one lookup, one name apart. `computer.this` names inputs on
hardware this PC is plugged into; any other name describes inputs it cannot
observe, so the trigger only ever runs `pull`.

## When it starts

| Answer | What is installed | Covers |
|---|---|---|
| From boot | a Scheduled Task with an S4U principal and RunLevel Limited, triggered at startup. Administrator once, to register; it then runs as you, unelevated, in session 0 | from boot onward -- before the first login, while locked, after a logoff |
| From login | the same task with an Interactive principal, triggered at logon | from your logon onward, including while the screen is locked |
| No | the same task with no triggers, started now | this session only; `restart` starts it again |

The tiers share one task name, so installing either replaces the other. If "from
boot" cannot be registered -- a declined UAC prompt, or an account with no
administrator rights -- it falls back to login, says so, and the config records
login. `status` says which tier is installed and what it covers, and `restart`
reports whether a watcher actually came up.

The two automatic tiers also carry a one-minute repeating trigger, which is what
brings a killed watcher back. Task Scheduler's own RestartCount does not: it
treats an ended task as complete rather than failed, so that interval IS the
recovery time. The "no" tier has no such trigger, or "no" would mean "yes, every
minute".

## The walkthrough and the checks

`trigger-kvm configure` is one menu: name the computers, say which computer is
on which input of each monitor, tick the devices that travel with the switch,
choose when it starts, test the inputs and the trigger while you watch, then
save. Nothing is written until Save. The contract is
[`../specs/configure.md`](../specs/configure.md); what is specific to this
platform:

- Standard DDC/CI is the default for every panel. The LG dialect is offered for
  LG panels, and only values from [`../displays.toml`](../displays.toml) or
  values you type are ever sent on it.
- Where a panel enumerated through both transports, the walkthrough asks which
  one to use and says the consequence: through Windows, that monitor does not
  follow the switch until somebody has logged in. Choosing it also disables the
  "from boot" row, and `status` names the panel it strands.
- A monitor check sends the panels in scope away and back and asks once; one
  panel always stays on this computer. Every path that moves a panel goes
  through that same warning -- a retry, and the transport-only check made when
  no other computer is configured, included.
- A pass belongs to the panels it checked and to their method, transport and
  map. Any edit to those puts the row back to `untested`, and the trigger check
  pulls for real only while every managed, attached panel holds a current pass.
- A configured monitor that is not attached today is shown as such, kept on
  Save, and not checked. Only unmanaging forgets it.
- The trigger check stands the installed watcher down first. On the boot tier
  that would need a password, so instead it says the running watcher will also
  fire, before you flip.

## Configuration

A flat `key = value` file, specified in
[`../specs/config-format.md`](../specs/config-format.md). It is machine-local:
`computer.this` differs per machine, and some panels report a different EDID
product id per input, so an id copied from another host matches nothing. Read
ids with `trigger-kvm list`.

Two devices of one model share a vendor:product id. Where that matters the
walkthrough writes `usb:VVVV:PPPP@token@where`
([`../specs/detector.md`](../specs/detector.md) 4.1). Two attached monitors of
one model are one identity; the switch refuses it, and `list`, `configure` and
`status` say so.

## Components

```
trigger-kvm.ps1     the switcher: list, pull, to, set. Runs on every arrival, so it stays lean
event-watch.ps1     the watcher, and the one owner of "is that device here?"
config.ps1          the shared vocabulary: the config format, the verbs, the transports
install.ps1         the entry point: paths, the parameters, and the verb dispatch
lib/menu.ps1        the two menus, the prompts, and the name rule
lib/answers.ps1     the walkthrough's state: the researched tables, one record per panel, load and write
lib/walkthrough.ps1 the walkthrough's flow
lib/checks.ps1      the monitor and trigger checks -- the only code here that moves a panel
lib/discover.ps1    what is attached right now, and the `discover` verb
lib/host.ps1        elevation, PATH, the task, the watcher, status, install and uninstall
nvapi-probe.ps1     a measuring instrument for the NVAPI bindings; never installed
```

**`trigger-kvm.ps1`** carries two transports in one embedded C# block.
`nvapi` sends aimed raw I2C at one GPU output: NVIDIA only, works with no
desktop, and the only one that can carry the LG dialect. `dxva2` uses Windows'
own DDC/CI stack: any adapter, but it goes through `user32` and therefore needs
a local console session. Absent, `transport` means `nvapi`, and neither is ever
a fallback for the other.

Identity is one key for both: the EDID vendor and product, which NVAPI reads off
the GPU output and dxva2 reads out of the PnP interface path. Never a `\\.\DISPLAYn`
name, which is not stable. Each write is aimed at the single output that
identifies as the panel, and anything other than exactly one match is refused.

**`event-watch.ps1`** is one process with two sources: USB through
`Win32_DeviceChangeEvent`, a WMI extrinsic event that reaches session 0, and
Bluetooth by P/Invoke to the classic `bthprops.cpl` API, polled and only when a
`bt:` device is configured. Bluetooth presence means CONNECTED; the candidate
list offers every PAIRED device. An arrival is debounced (`trigger.debounce`,
default 3 s) and settled (`trigger.settle`, default 0.75 s): it fires only if
the device that arrived is still there. Devices present at startup never fire.

A watched entry is in one of FOUR states, not two: `present`, `where` (present,
and the remembered port is what said which device this is), `absent`, and
`ambiguous` -- more than one device answers to the id and none is at the
remembered port. **An arrival is `absent` -> `present` and nothing else**, so
unplugging one of two identical devices resolves the entry without firing
anything, and a watcher whose every entry is ambiguous refuses to start rather
than running and never firing.

```powershell
event-watch.ps1 -Exec PATH [-Arg pull] -Device usb:VVVV:PPPP[@token[@where]]|bt:AAAAAAAAAAAA
                [-Debounce S] [-Settle S] [-LogFile PATH] [-MaxLogBytes N] [-Config PATH] [-Verbose]
event-watch.ps1 -ListUsb          what could be a trigger: container|vid|pid|token|where|name
event-watch.ps1 -ListBluetooth    every paired device: address|connected|name
event-watch.ps1 -Report           how each entry resolves now: entry|present|where|absent|ambiguous
event-watch.ps1 -IsRunning        is a watcher running, from the lock. Exit 0 means yes
event-watch.ps1 -TestTrigger -Device ... [-Timeout S]   report ONE arrival and exit, running nothing
```

The listing and reporting modes need no config and refuse nothing: they have to
answer on a machine with no config at all, because they are what `configure` is
built on.

Single instance is a named mutex: `Global\`, so it covers the whole computer and
not one session, falling back to `Local\` only where the account may not create
a global name. A lock that cannot be established for any reason other than
"held" is a refusal, never a watcher that runs unlocked. A watcher that finds the global name held by another account
stands down rather than falling back, or the two tiers would each get a watcher.
A force-killed watcher leaves the mutex ABANDONED, which is a normal condition
here and not an error -- see [`AGENTS.md`](AGENTS.md). The log rotates at
startup, after the lock, and nowhere else.

The task runs `wscript.exe launcher.vbs`, which runs `powershell.exe`, because
powershell is a console-subsystem binary and would flash a window at every
logon. The watcher is therefore a GRANDCHILD of the task: stopping the task does
not stop it.

## Running a watcher by hand

```powershell
trigger-kvm pause                          # stand the installed one down; never kill it
.\event-watch.ps1 -Exec .\trigger-kvm.ps1 -Arg list -Verbose
trigger-kvm restart                        # put the installed one back
```

`pause` disables the task as well as stopping it, because the self-heal trigger
would otherwise start it again within the minute. Run the hand-run watcher with
`-Verbose`: one physical plug produces dozens of device-change events, and the
line saying an event yielded no arrival edge is the only way to tell "no event
delivered" from "delivered and correctly rejected".

## Testing

```powershell
cd windows\tests
.\run.ps1                    the suite; no hardware needed
.\run.ps1 menus              only files whose name matches
.\mutate.ps1                 reintroduce each bug the suite should catch
```

The suite cannot move a monitor: `Send-Input`, the one place the installer emits
a packet, is stubbed, and every menu is driven end to end through its typed
fallback. Each file runs in its own process, because the walkthrough tests
define stubs with the same names as real functions. A test that did not run
reports `SKIP` and never counts as a pass -- two files need real hardware, and
one case inside them needs a local console session rather than a remote one.

Before running anything against the monitors, check that it parses. Windows
PowerShell 5.1 reads a `.ps1` with no BOM as ANSI, so a non-ASCII character in a
comment surfaces as a parse error at an unrelated line:

```powershell
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\trigger-kvm.ps1', [ref]$null, [ref]$e)
$e
```

`tests\conventions.tests.ps1` scans for the rules no single mutation can test:
one door to I2C source `0x50`, one door to "whose install is this?", no function
defined twice or shadowing a cmdlet, the word "machine" never shown to a user,
one verb surface, one transport table, the watcher asked of the lock rather than
of the process table, and the instruction-file byte budget.
