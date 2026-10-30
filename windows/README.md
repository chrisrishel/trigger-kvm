# trigger-kvm on Windows

A watcher (`event-watch.ps1`) runs `trigger-kvm pull` when a configured device
arrives; `pull` resolves each configured monitor by the EDID it reads at that
moment and sends it the input-select write over DDC/CI. The shared behaviour is
specified in [`../specs/`](../specs/); the safety rules are in
[`../AGENTS.md`](../AGENTS.md) and this platform's hazards in
[`AGENTS.md`](AGENTS.md).

## Requirements

64-bit Windows 10 or 11, Windows PowerShell 5.1, Task Scheduler, WMI/CIM, and
Windows Script Host with VBScript enabled. No PowerShell modules or bundled
third-party executables are required. Git is optional for acquiring/updating the
source. Downloaded scripts must be trusted and permitted by local policy.

`nvapi` requires an NVIDIA GPU and its installed driver; the DLL is loaded only
from the Windows system directory. It supports the boot tier and the LG dialect.
`dxva2` carries standard DDC/CI only and requires a **local console session**;
neither an RDP login nor session 0 is sufficient. It is an explicit transport
choice, never an automatic fallback when NVIDIA is absent.

Validation is bounded to the reference Windows 11 desk, RTX 4090, LG 45GX950A
and ASUS PG42UQ. NVAPI physical switching has dated observations in
[`../docs/measurements.md`](../docs/measurements.md). The shipped dxva2 path moved
the ASUS both ways at the local console, visually confirmed on 2026-10-29.
Other monitors, adapters and Windows versions are not established by fixture tests. Fresh
administrator/standard-user profiles and autostart transitions remain release
checks in [`RELEASE-CHECKS.md`](RELEASE-CHECKS.md).

## Install

```powershell
# From a directory where you keep source checkouts; repository access is required.
git clone https://github.com/chrisrishel/trigger-kvm.git
cd trigger-kvm\windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath
```

Alternatively, extract a trusted source archive and open PowerShell in its
`windows` directory. If Windows marked the download as blocked, review the
source, then unblock only those scripts:

```powershell
Get-ChildItem -LiteralPath . -Filter *.ps1 -File -Recurse | Unblock-File
```

`-ExecutionPolicy Bypass` applies to this process; it does not change machine
policy or override organizational policy. Start **unelevated** as the user who
will own the installation. Omit `-AddToPath` to keep PATH unchanged. Open a new
terminal after adding PATH, or use the installed shim immediately:

```powershell
& "$env:LOCALAPPDATA\Programs\trigger-kvm\bin\trigger-kvm.cmd" status
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
trigger-kvm pull                 # point every configured monitor at THIS computer
trigger-kvm to mac               # another saved computer name; manual only
trigger-kvm list                 # attached displays, with EDID ids and names
trigger-kvm configure            # the walkthrough; -Fresh pre-fills nothing
trigger-kvm status               # watcher state, saved config, input map and build identity
trigger-kvm discover             # attached USB devices and paired Bluetooth devices
trigger-kvm restart              # make trigger edits take effect now
trigger-kvm logs                 # tail the log; Ctrl+C stops tailing
trigger-kvm pause                # stand the watcher down to test by hand
trigger-kvm uninstall            # remove program/task/PATH; keep config and log
```

Two flags matter when you are testing, and both are the switcher's:

```powershell
.\trigger-kvm.ps1 pull -Only asus     # one saved monitor label; substitute yours
.\trigger-kvm.ps1 pull -WhatIf        # resolve and print packets, send nothing
```

The bare command prints the verbs and exits 2. There is no `install` verb and no
`apply` step: display edits take effect on the next switch, trigger edits when
the watcher next starts, which `restart` does.

`pull` and `to` are one lookup, one name apart. `computer.this` names inputs on
hardware this PC is plugged into; any other name describes inputs it cannot
observe, so the trigger only ever runs `pull`.

Before a manual switch, move the terminal to a monitor that will stay on this
computer. Use `-Only` for one monitor at a time and confirm the result by eye.
A successful command or dry run does not establish that a panel moved.

## Upgrade, repair and uninstall

Preserve local work when updating the source. From the checkout root:

```powershell
git status --short
git fetch origin
git merge --ff-only origin/main
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\install.ps1
```

If fast-forwarding is refused, resolve the local work deliberately; do not reset
it away. The source installer preserves the saved configuration and existing
autostart choice, replaces installed scripts, and restarts the watcher. An
upgrade is disruptive to the watcher, so coordinate it before testing devices.
Run `trigger-kvm status` afterwards and inspect the version stamp and lock state.
The product version, specification revision and source commit are separate;
reconfiguring an installed copy preserves its build stamp.

Process cleanup requires the exact installed script path and intended owner.
For PowerShell it recognizes `-File`, optionally preceded by `-NoProfile`,
`-ExecutionPolicy Bypass` and `-WindowStyle Hidden` in that order, as generated
by the installer. Command-mode wrappers, implicit commands and unrecognized
launch syntax are left alone. A watcher started through a custom wrapper may
therefore need to be stopped from the console that started it before upgrading.

`trigger-kvm uninstall` works from the installed shim even after the source is
gone. Config and logs remain in `%LOCALAPPDATA%\trigger-kvm\`; retain them for a
reinstall or remove them yourself after reviewing their contents. A boot-tier
task can require UAC for removal. If removal fails, the installer leaves the
program files in place and explains the remaining task.

## When it starts

| Answer | What is installed | Covers |
|---|---|---|
| From boot | a Scheduled Task with an S4U principal and RunLevel Limited, triggered at startup. Administrator once, to register; it then runs as you, unelevated, in session 0 | from boot onward -- before the first login, while locked, after a logoff |
| From login | the same task with an Interactive principal, triggered at logon | from your logon onward, including while the screen is locked |
| No | the same task with no triggers, started now | this session only; `restart` starts it again |

The tiers share one task name, so installing either replaces the other. If "from
boot" cannot be registered -- a declined UAC prompt, or an account with no
administrator rights -- it falls back to login, says so, and the config records
login. If you approve the prompt and the elevated install then fails, it stops
and says so instead: elevation was obtained, so that is not the fallback, and
installing a different tier on top would be a second install you did not ask
for. `status` says which tier is installed and what it covers, and `restart`
reports whether a watcher actually came up.

**One admin run poisons the task for later unelevated ones.** The definition
under `System32\Tasks` belongs to whoever registered it, so after an
administrator install -- including the boot tier's -- an ordinary `install` or
`uninstall` fails with `Access is denied`. Both say so. To recover, run
`uninstall` from an elevated PowerShell once, then install normally.

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
  one to use and says the consequence: dxva2 needs a local console session.
  Choosing it also disables the
  "from boot" row, and `status` names the panel it strands.
- A monitor check sends the panels in scope away and back and asks once; one
  panel always stays on this computer. Every path that moves a panel goes
  through that same warning -- a retry, and the transport-only check made when
  no other computer is configured, included.
- A pass belongs to the panels it checked and to their method, transport and
  map. Any edit to those puts the row back to `untested`, and the trigger check
  pulls for real only while every managed, attached panel holds a current pass.
  Declined, skipped or incomplete checks cannot grant that pass. Escape discards
  computer, removal and monitor submenu edits; Done accepts them in memory.
- A configured monitor that is not attached today is shown as such, kept on
  Save, and not checked. Only unmanaging forgets it.
- The trigger check stands the installed watcher down first. On the boot tier
  that would need a password, so instead it says the running watcher will also
  fire, before you flip. Where it can pause, every exit restores the prior task
  enablement and running state, including a deliberately paused installation.

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

`status` resolves each trigger in the **current saved configuration** against
devices attached now, using the watcher's resolver. It does not inspect the
configuration loaded by an already-running watcher. Trigger edits require
`trigger-kvm restart`. Display input maps are assertions about cables, never
verified by a readback. UTF-8 configuration preserves Unicode display names and
unknown values across Save and autostart updates.

Before sharing status, discovery, probe output, configuration or logs, redact
Bluetooth addresses, serials, device tokens/locations and personal paths. Keep
vendor/product IDs and protocol values needed to explain the problem; see
[`../CONTRIBUTING.md`](../CONTRIBUTING.md#reporting-a-bug).

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
Bluetooth by P/Invoke to the classic `bthprops.cpl` API, enumerated once per
event-driven presence sweep when a `bt:` device is configured. Bluetooth
presence means CONNECTED; the candidate
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

```text
event-watch.ps1 -Exec PATH [-Arg pull] -Device usb:VVVV:PPPP[@token[@where]]|bt:AAAAAAAAAAAA
                [-Debounce S] [-Settle S] [-LogFile PATH] [-MaxLogBytes N] [-Config PATH] [-Verbose]
event-watch.ps1 -ListUsb          what could be a trigger: container|vid|pid|token|where|name
event-watch.ps1 -ListBluetooth    every paired device: address|connected|name
event-watch.ps1 -Report           how each entry resolves now: entry|present|where|absent|ambiguous
event-watch.ps1 -IsRunning        is a watcher running, from the lock. Exit 0 means yes
event-watch.ps1 -TestTrigger -Device ... [-Timeout S]   report ONE arrival and exit, running nothing
```

The listing modes need no config. `-Report -Device <entries>` resolves explicitly
supplied entries without taking the watcher lock; malformed entries are refused.
With no explicit entries it uses the saved config.

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
.\run.ps1                    # full suite; hardware-dependent cases report skips
.\run.ps1 menus              # only files whose name matches
.\mutate.ps1 publication     # publication regression mutations
.\mutate.ps1                 # all mutations; run alone, as it edits/restores source
```

The suite cannot move a monitor: `Send-Input`, the one place the installer emits
a packet, is stubbed, and every menu is driven end to end through its typed
fallback. Each file runs in its own process, because the walkthrough tests
define stubs with the same names as real functions. A test that did not run
reports `SKIPPED` and never counts as a pass. Transport cases require real
graphics hardware; the dxva2 case requires a local console session, and the
native NVAPI module-path case is skipped without an NVIDIA driver.
Native publication checks exercise harmless WSH/process/DLL fixtures and hidden
console buffers. `native-cleanup.tests.ps1` checks real PowerShell 5.1 command
forms and generated launcher cleanup, restricting CIM enumeration to its own
bounded fixture PIDs. No real task is registered or altered by the suite. The
coordinated installation and physical checks are in
[`RELEASE-CHECKS.md`](RELEASE-CHECKS.md).

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
