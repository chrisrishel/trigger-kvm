# Windows side

A Scheduled Task runs `event-watch.ps1`, which fires `trigger-kvm.ps1 pull`
when a watched USB device arrives. No compiled code and no third-party binary:
PowerShell throughout, with the NVAPI bindings inline.

Both panels use one transport -- raw I2C through NVAPI, each **aimed at the single
GPU output whose EDID identifies that panel**. Neither write is a spray; no monitor
receives the other's packet.

| Monitor | Target input | I2C source | VCP | Packet |
|---|---|---|---|---|
| LG 45GX950A | DisplayPort, `0xD0` | `0x50` (LG sidechannel) | `0xF4` | `50 84 03 F4 00 D0 9D` |
| ASUS PG42UQ | HDMI 1, `0x11` | `0x51` (standard) | `0x60` | `51 84 03 60 00 11 C9` |

Values are in [`../displays.toml`](../displays.toml). Keep them in sync -- that file
exists precisely so these two implementations can't drift.

## Requirements

- NVIDIA GPU. Both panels are driven by raw I2C through NVAPI. This is not a
  preference: the LG's input lives on I2C source `0x50`, and the Windows DDC/CI
  stack hardcodes source `0x51` and cannot express `0x50` at all, so no
  vendor-neutral API can reach it. Verified on an RTX 4090, driver 32.0.16.1062.

  The requirement predates the NVAPI transport -- the LG has always needed it, and
  the tool used before, `lg-input-switch.exe`, was itself an NVAPI program. A
  standard-DDC panel *could* be driven on any GPU through `dxva2`; supporting that
  is a generalisation question, taken up in
  [`../docs/decisions/001-nvapi-as-the-only-windows-transport.md`](../docs/decisions/001-nvapi-as-the-only-windows-transport.md).
- Windows PowerShell 5.1 (stock). No admin rights needed, at install or at run time.

## Install

From the source tree — this is what installing *is*:

```powershell
.\install.ps1                 # copy files, register the task, start it
.\install.ps1 -AddToPath      # ...and put `trigger-kvm` on your PATH
```

With no config yet it runs the walkthrough for you. Afterwards it is one command
from anywhere:

```
trigger-kvm configure          interactive; current settings pre-fill the defaults,
                               and it applies whatever you changed
trigger-kvm configure -Fresh   ...but pre-fill nothing, and ask everything again
trigger-kvm status             when it starts, what that covers, version
trigger-kvm discover           what is attached, in the form the config wants
trigger-kvm restart            make a hand-edited config take effect now
trigger-kvm logs               tail the log
trigger-kvm pause              stand the watcher down to test one by hand
trigger-kvm uninstall
trigger-kvm pull | to <computer> | list
```

### Tests

```powershell
cd windows\tests
.\run.ps1                 # all of them
.\run.ps1 menus           # just one file
.\run.ps1 -Verbose        # every prompt and answer
```

No framework. The Pester that ships with Windows PowerShell 5.1 is 3.4, and requiring
`Install-Module` would put a gallery dependency in front of a project whose whole
claim is that it needs nothing but stock PowerShell. A test here is a script that
throws when something is wrong.

Each file runs in its own `powershell.exe` — not tidiness: the walkthrough tests
define stubs with the same names as real functions, and `types.tests.ps1` deliberately
loads a stale copy of the switcher into its runspace.

| file | what it holds down |
|---|---|
| `menus.tests.ps1` | cursor, the `Done` button, separators, `(current)`, and that nothing is ever truncated |
| `walkthrough.tests.ps1` | the whole flow with scripted answers — first run, re-run, `-Fresh`, dialect escalation, blind walking, duplicate inputs |
| `monitor-check.tests.ps1` | batching on a four-panel desk, the window's panel being scheduled last, and the single-monitor pre-flight |
| `trigger-check.tests.ps1` | that the result is one object whatever the child printed, and that it only pulls once the monitors are proven |
| `display-question.tests.ps1` | the one place a human's answer becomes a diagnosis: every answer, to the right outcome |
| `resolve.tests.ps1` | the real switcher under `-WhatIf`: the exact packets, and every refusal |
| `types.tests.ps1` | the loaded-type guard still fires, and the installer cannot trip it |
| `spec.tests.ps1` | conformance to [`../specs`](../specs), and that this side is level with the changelog's revision |
| `conventions.tests.ps1` | no function defined twice in one file, nothing named after a real cmdlet, and "computer" never "machine" in anything the user reads |
| `stdin.tests.ps1` | the real `configure`, as a real process, driven by a real answer stream |

`Send-Input` is stubbed throughout, so the suite cannot move a monitor. The harness
runs `Set-StrictMode -Version Latest` because the scripts do — without it a whole
class of failure is invisible in the tests and lands on the user instead.
`resolve.tests.ps1` needs the reference panels attached and says so and skips when
they are not.

**They are mutation-checked.** Passing tests prove nothing until they can fail, so
every regression the suite is meant to catch gets reintroduced deliberately and the
test has to go red. Several did not, first time, and each was a test that looked
right and asserted nothing:

- `Write-MenuFrame` truncating again *passed* — `Split-Detail` pre-wraps, so a
  `Substring` only bites on a single unbreakable item, and that case had to be added.
- "the escalation shows its values" passed with the value listing deleted, because
  the same values reappear in the input menus afterwards. The assertion now pins the
  **order**, which is what the spec actually says.
- the conformance checker's two length floors collapsed into one and stayed green,
  because the fixtures sat on the wrong side of the boundary — a "too short to pin"
  fragment that turned up in the sources anyway, and a "whole line" that was over
  the floor being tested.

### The walkthrough

Every list question is an arrow-key menu, and the rule is the same in all of them:
**enter does what the highlighted row says**. So a multi-select has no accept key —
it has a `Done` row you move to, with a live count of what it will use sitting in
the detail column where every other menu puts a value:

```
  > [x] usb:046d:0843    USB   Logitech Webcam C930e
    [ ] bt:0011223344ff  BT    AirPods Pro  (paired, not connected)
    [x] usb:1235:820a    USB   Clarett+ 2Pre

        Done                     2 selected
```

(The first version had "space toggles, enter accepts" and lost people immediately:
enter is what you press, so the first thing it did was accept an empty list. The one
after that drew `Done` as a bracketed button, to stop it reading as a fourth thing to
check — but the blank line above it and the missing checkbox already say that, and
every other menu here ends with a bare `Done`.)

A multi-select lays its rows out the way every other menu does — the same item
column, the same wrapping of the detail at the `", "` between items. It is where
that matters most: device names are long and come from the system rather than being
chosen, and a row that overflows wraps, leaving a tail the next frame does not
clear.

Every menu falls back to a typed number when the host cannot read individual keys —
redirected stdin, some remote sessions — which is also what makes the flow testable
end to end. `configure` reads that answer stream from **standard input**, not from
`Read-Host`, which in Windows PowerShell 5.1 reads the console and never sees a
piped answer at all.

**Esc always means "take me to the way out"**, and what the way out is depends on
the menu:

| menu | esc does |
|---|---|
| a submenu you entered from somewhere | returns, changing nothing — the triggers you had stay selected, the computers keep their names |
| the main menu | moves the cursor to `Cancel`. It does **not** press it |
| a question that must be answered | nothing |

On the main menu it moves rather than acts, so a setup still cannot be discarded by
a stray keypress: you have to press enter on a row that says
`Cancel (discard changes)`. In the typed fallback the same thing is `q`.

**A monitor's questions are one submenu, not several.** Esc at any of them — how
to talk to it, or any input — abandons that panel and returns to the Monitors
list, leaving it exactly as it was. Half a map is not an answer, so nothing
part-way through is kept.

That is deliberately *not* the same outcome as answering `Manage this monitor?`
with **no**, which takes the panel out of the config. Backing out and declining
are different things, and collapsing them would let a stray esc silently unmanage
a working monitor.

**Anything that discards configuration says what it discards, and asks.** Two
places do that, and they are the same rule rather than the same keystroke:

- `Manage this monitor?` → **no** forgets which computer is on which of that
  panel's inputs, so it confirms and names the loss. A panel with nothing
  configured has nothing to lose and is not asked twice.
- `Remove a computer` clears that computer's input on every monitor, so the row
  names those monitors *before* it is chosen and the confirm restates it.

Both default to **no**.

Renaming a computer is not one of them: the prompt is pre-filled and **enter
keeps the name**. It used to *remove* the computer on a blank answer, which made
the most innocuous keypress available the destructive one — the same failure as
accepting an empty multi-select, which the menu grammar already exists to
prevent. Removal became a row rather than a delete key because a keypress has no
typed-fallback equivalent, and the typed fallback is what the suite drives.

**The menu is the whole flow.** There is no separate first-run questionnaire: an
empty install is this same menu with `not set` in it and the cursor already on the
first thing that needs an answer. Finishing a section comes straight back here, with
the cursor on the next unanswered one — so "done" means the same thing everywhere,
and there is one place a change has to be made rather than two.

```
--- review configuration ---

    Computers                    pc (this), mac
    Monitors                     asus: pc/mac, lg: pc/mac
    Triggers                     usb:046d:0843, bt:0011223344ff
    Autostart?                   from boot
    Add to PATH?                 yes

  > Test the monitor inputs      untested
    Test the triggers            untested

    Save configuration and run
    Cancel (discard changes)
```

**One punctuation rule down the value column**, because it is read as a column:
`, ` separates items, `: ` separates a label from its value, `/` joins things
sharing one label. Not only tidiness — `Split-Detail` wraps at `, `, so while the
monitors row used spaces it could not wrap at all, and a desk with several panels
overran the line while every other row behaved.

Three groups: what you set, what you can check, and what ends the walkthrough.
Seven flat rows read as seven equal choices, so the separators do the work that
renaming the rows to imply grouping would have done badly.

```
--- configuration ---

  > Computers                    not set
    Monitors                     not set
    Triggers                     not set
    Autostart?                   not set
    Add to PATH?                 not set
```

**Nothing is preset.** Autostart and PATH both have an obvious answer — from boot,
and yes — but the suggestion belongs on the highlighted row *inside* their menu, not
in the value column of a menu nobody has opened. Showing `from boot` for a choice
nobody made is the tool answering on someone's behalf, and that particular one
raises a UAC prompt; the other edits your PATH. So both are `not set` until chosen,
the cursor walks to them in turn, and save waits for them.

Choosing a setting enters that section and returns here — a menu rather than a
linear pass, because the answer you got wrong is rarely the last one you gave.
Nothing is written until you pick save, and save refuses while a required section is
still `not set`, naming what is missing: writing half a setup produces a config the
switcher then declines to act on, which is a worse way to find out.

**A rename is carried, not re-asked.** Renaming a computer used to drop you into the
monitor questions, on the theory that every panel's map now named something that did
not exist. It does not have to: the rename is applied to every map, a removal takes
that computer out of them, and an addition leaves them alone — the Monitors row then
simply shows which panels do not know about it yet.

**Where the cursor lands is the recommendation**, and it walks the checks in order:
trigger, then monitors, then save. A failure sends the cursor to the setting that
failed rather than onward. Neither pass survives editing what it was a pass *for* —
it belonged to those values, and showing "all responded" beside numbers nothing
tried would be a claim the user has no way to catch.

**Monitors are a list you pick from**, the same shape as the computers list and for
the same reason: walking every panel in sequence to change one value meant answering
for all of them, which is what a menu exists to avoid.

```
--- monitors ---

  > PG42UQ                       asus: pc/mac
    LG ULTRAGEAR+                not managed

    Done
```

**An input already taken keeps its name, its place, and cannot be chosen.**

```
  On the PG42UQ, which input is 'mac' on?
   1) DisplayPort 1                0x0F
   2) DisplayPort 2                0x10
   -- HDMI 1                       0x11   assigned to pc
   4) HDMI 2                       0x12
```

Two computers cannot share a socket, so this is not merely discouraged — it is not
an answer. The earlier version put assigned computers at the *front* of the list
under their own names, so answering for the second computer showed `pc  0x11` where
`HDMI 1  0x11` had been, and the rows moved as you went. `HDMI 1` is what the
monitor's own menu says, and it is the only label worth showing.

**"Test the monitor inputs", not "the monitors".** What is under test is the claim
that input V of panel P is computer C — a panel that answers every command perfectly
while its inputs are mapped to the wrong computers fails this, and is not broken.

**The inputs are checked before the triggers, and that ordering is the point.**
The trigger check asks you to flip the switch away and back — and once the monitor
values have been confirmed by someone looking at them, the flip *back* pulls the
monitors here for real, using those values. So it stops being "an event was
observed" and becomes the whole thing working end to end, which is the last thing
worth seeing before saving. Until the monitors are checked it reports the arrival
and deliberately does **not** move anything: pulling aims real values at real
panels, and unverified ones could leave the desk somewhere nobody meant.

**Testing the trigger watches for a real arrival.** `event-watch.ps1 -TestTrigger`
prints what is present now, then waits for one of the chosen devices to *arrive* —
the same event that fires a switch — and reports it. It lives in the watcher for the
same reason the Bluetooth listing does: that script owns presence, and a second
implementation in the installer would be free to disagree with the one that
actually fires, which is the worst possible place for a disagreement. It takes no
lock and runs nothing, so a real watcher may be running alongside.

### Monitors nobody has met

**The panel says its own name.** It comes out of the EDID (descriptor tag `0xFC`) —
`PG42UQ`, `LG ULTRAGEAR+` — so there is no name table to be absent from. Asking the
hardware beats a database, which only ever knows the monitors its author owned.

**Every panel starts on standard DDC/CI**, whatever the make: I2C source `0x51`,
VCP `0x60`, MCCS values. That is what nearly everything answers to.

**Manufacturer dialects are keyed by vendor, and offered, never probed.** `$DIALECTS`
holds one row today — EDID vendor `1E6D` (LG), source `0x50`, VCP `0xF4`, values
`D0 D1 90 91`. The values are always *shown to you and offered*, because a value
nobody documented is a value nobody should send (hard rule 1: a "Bricked LG Monitor"
issue exists). The old table was keyed vendor:product — one row per monitor someone
here happened to own, on a panel whose product id is per-*input*, so the key was
nearly per-cable. The transport had this right all along: `WriteLgInput` gates on the
vendor and does not care which LG it is.

**The choice is offered up front, and again if the check fails.** Configuring a
panel whose vendor has a documented alternative asks which method to use, right
after its short name and before any input question — the values on offer depend on
the answer. Standard is the default and stays the default. It used to be reachable
only by failing the check first, which made someone who already knew their model
needed it move a panel and send packets purely in order to fail, and gave someone
who did not know it existed no reason to think the tool had heard of it.

The check still offers it, and now **in either direction**: a panel on standard that
answers nothing is offered the manufacturer method, and a panel already on the
manufacturer method that answers nothing is offered standard. Either way the map is
cleared — every value in it was an address on a channel that does not work.

**The test asks what was watched, in the order it happened**, because the outcomes
have entirely different fixes and a yes/no could only see two of them:

```
  Did the LG ULTRAGEAR+ change to mac, and back to pc?
  > Yes, and it changed back to pc         everything works
    Yes, but it did not change back to pc  the input for pc is wrong
    No
```

Only a `No` is taken apart, with a second question — `Did the LG ULTRAGEAR+ change
at all?` — separating "that input is not mac" (a wrong *mapping*) from "nothing
happened" (a wrong *channel*). One question with four answers made the reader hold
every failure in mind at once to find their own; this asks about the thing they just
watched, and the common answer is the first one.

"Did not come back" means the channel is right and this computer's input is wrong —
so it asks again, or walks the values for you. "Nothing at all" means the channel is
wrong — so it offers the other one, whichever way round that is, and says plainly
that nothing known reaches this panel when there is no other one to offer. Each fix
retries immediately rather than sending you back to the review menu.

**Blind value-walking is the last resort**, and only ever on standard DDC: each MCCS
value in turn until the panel comes back. It is offered rather than automatic, with
the cost stated first (every wrong value moves that panel; if none is right it stays
there), and **refused outright when it would take the last display** — hard rule 4,
and the question would otherwise be printed on the screen it just blacked out.

**You name your own inputs.** After a monitor comes back, it asks what was on the
input it visited. Your answer is stored as `display.lg.input.0xd1 = Mac` — value
first, so the name survives exactly as typed — and offered ahead of the standard
names on every later run. "Mac" is a better label than "HDMI 2", and it is the only
one that is true about your room.

**Checking the monitors batches across panels, never across computers.** Monitors sit
side by side, so several can be confirmed in one glance; a *sequence* of switches
over half a minute has to be held in memory and reported afterwards, and memory is
the weak link. So each round sends every panel that claims a computer to that computer
at once and asks straight away:

```
  Sending ASUS, DELL and BIG to mac for 8s, then back automatically.
  LG stays here, so you can read this.

  Did all of them show mac, then come back?  [Y/n]
```

The win is the question, not the wall clock. The common case — everything worked —
is one keystroke, and the four-way diagnosis only appears for the panels you say
went wrong ("Which ones did not?"). At two monitors that replaces two menus with one
yes/no; at four panels and three computers it replaces twelve with four.

**It asks which monitor you want to check** — `All of them`, or one — and then, every
round, says what is about to move:

```
  LG ULTRAGEAR+ stays here, so you can read this.
  If this window is on PG42UQ, drag it to LG ULTRAGEAR+ first: if the switch back
  fails, the window goes dark with it and there is no way to answer.

  Enter when ready
```

It used to ask where *this window* was, so it could schedule that panel last. Saying
what is about to move gives the same protection, is one fewer question, and asks
about something the person actually knows — where they want to look, rather than a
detail of the tool's scheduling. Checking one monitor still leaves the others
counted as somewhere to move a window to, because they are still on this computer.

**With one monitor you can genuinely get stuck, so it says so first.** Nothing can be
held back, and if the switch back fails this tool cannot draw on a screen that is
showing another computer. The way back is the monitor's own input button — so the
pre-flight names the input in the panel's own words (`HDMI 1, value 0x11`), never as
a computer name the OSD has never heard of, and waits for a Ready? before sending
anything. Declining reads as **not checked**, never as a pass.

**Testing the monitors happens before anything is written.** The switcher takes a panel's method
and identity from a config file rather than from the command line — deliberately,
so there is one description of a panel and not two — so the test writes a throwaway
config, uses it, and deletes it. The alternative was writing the real config early,
which would have traded the "nothing is written until you save" rule for a
convenience.

The test switches a panel away for eight seconds and brings it **back
automatically** before asking anything, so the question always arrives on a display
that has already returned. It only has to *change* — "No Signal" on an empty input
proves the switch just as well.

Anywhere a value is already configured, its row is marked `(current)`. Starting the
cursor there is not enough on its own: the cursor also means "where you are", so on
a re-run there was no way to tell an unchanged default from a deliberate choice.

**"When should it start watching?" offers from-boot first, and defaults to it**, so
a PC sitting at a login screen still follows the switch. The cost is one UAC prompt
during setup, which beats discovering months later that switching quietly does
nothing until someone logs in. A config that already says otherwise still wins — an
existing choice is a choice. A *headless* install still defaults to the no-admin
tier, because it cannot ask: nothing elevates without someone choosing it.

`configure -Fresh` asks everything again with **nothing pre-filled**, for when the
desk changed enough that the old answers are the wrong starting point and
enter-through would carry a stale value forward unread. It clears the *defaults*,
not the answers you already gave, which still pre-fill nothing but themselves.

**There is no `install` verb on the CLI**, deliberately: installing is what got you
the CLI. Upgrading and repairing both mean "fetch the source and run its installer",
which works because the install is self-contained — `install.ps1` copies itself, so
managing and removing keep working after the source tree is gone.

**And no `apply` step.** One used to be needed because trigger settings were baked
into the scheduled task's command line, so every config edit required re-registering
the task — a coupling nobody could see, and the reason that verb never had a good
name. The watcher now reads the config itself, the task action carries no
configuration at all, and edits take effect when it next starts. `configure`
restarts it for you; `restart` exists for hand-edits.

**Verbs, and the same verbs on macOS.** You use both computers daily, so the words
typed constantly are where cross-platform muscle memory is worth buying. Flags stay
idiomatic per platform — `-AddToPath` here, `--add-to-path` there — because forcing
the POSIX spelling into PowerShell means hand-parsing `$args` and losing parameter
binding, validation and completion, which is a real cost for a cosmetic gain.

**There is no "tier" any more, and no flag for when it starts.** It was the internal
name for the boot-vs-login distinction and it leaked into the CLI, the status
output and the config. A name like `s4u` tells a reader nothing they can act on;
what they want to know is whether a locked or logged-out PC still follows the
switch. The walkthrough asks in those words, the config records
`install.autostart = boot|login`, and the installer applies what it finds — so the flag
was redundant with a config the installer already had to read. Old configs saying
`install.tier = s4u|user` are still honoured, with a warning, and `configure`
rewrites the file without them.

**Only `bin\` goes on PATH, and it holds exactly one file.** Putting the whole
install directory there would publish every file in it as a global command, because
`PATHEXT` includes `.VBS` — measured, `launcher.vbs` resolves as a bare `launcher`,
a generic name that starts the watcher. The `.ps1` files are safe only by *default*;
anyone who has added `.PS1` to `PATHEXT` would also get `install` and `config` as
global commands. A `bin` directory with one file in it cannot do any of that.

What ends up on your machine:

```
%LOCALAPPDATA%\Programs	rigger-kvm\        the program
    bin	rigger-kvm.cmd                     <- the only thing on PATH
    trigger-kvm.ps1                         the switcher
    event-watch.ps1                         the watcher
    config.ps1                              shared config reader
    install.ps1                             itself, so uninstall works without the repo
    launcher.vbs                            console-free shim for the scheduled task
    version.txt

%LOCALAPPDATA%	rigger-kvm\                 your data -- survives uninstall
    config
    trigger-kvm.log
```

Plus one scheduled task named `trigger-kvm`. That is everything.

**`trigger-kvm` is a `.cmd`**, so it runs from cmd, PowerShell and the Run dialog
alike with no execution-policy friction. It routes `pull`/`to`/`list` to the
switcher and everything else to the installer: two scripts behind one command,
because `trigger-kvm.ps1` runs on **every** device arrival and is kept lean while
`install.ps1` is large and rare.

**Answering "from boot" prompts for UAC.** It raises the elevation prompt and carries
on, rather than sending you to find an admin terminal — and `uninstall` does the same,
because registering an S4U task leaves the definition admin-owned, so removing it
needs elevation too. A prompt on the way in without one on the way out would trap you
in a setup you could not remove.

**If you are not an administrator, someone else can approve that prompt.** Windows
then elevates *their* account, not yours, so the installer tells the elevated half
who the install is for: your account name and your `%LOCALAPPDATA%`. The task is
registered to run as **you**, the files land in **your** profile, and only the
unelevated half — the one running as you — touches your `PATH`. Nothing about the
switch path changes: it still runs as you, unelevated.

**A trap worth knowing.** Running the installer from an *elevated* shell — easy if
you have one open — leaves the task definition Administrators-owned, so later
*unelevated* runs need elevation as well. Both paths detect it and offer the prompt
instead of throwing. To get back to a fully unelevated install: `uninstall`, then
install again normally.

### Two tiers

Pick by what you are willing to grant. They are mutually exclusive by construction
-- one task name, so installing either replaces the other.

| | user (default) | s4u |
|---|---|---|
| Admin to install | **no** | **yes**, once |
| Elevated at run time | no | **no** |
| Runs | at logon, your session | at startup, session 0, as you |
| From logon onward | yes | yes |
| While **locked** | **yes** | yes |
| Before first login after boot | no | **yes** |
| After a full logoff | no | **yes** |

The locked row is the one that surprises people, and it is why **from login** is
enough for most days: locking does not end your session, so the watcher is still
alive and the displays still follow. **From boot** buys the two genuinely uncovered
cases. The one that stings is a rebooted PC sitting at a login screen you cannot see,
because the monitors are still showing the other computer — which is why it is the
suggested answer.

`status` reports when it starts *and* what that covers, deliberately: a name on its
own invites you to guess the capability, and the capability is the entire point.

```
autostart: at boot  (principal=user logon=S4U runlevel=Limited)
           covers: from boot onward -- before first login, while locked, after logoff
```

**The tier is a property of the host, not of the switcher.** All tier logic lives in
`install.ps1`. Neither `trigger-kvm.ps1` nor `event-watch.ps1` knows or asks which
tier it is running under. If either ever needs to, the abstraction is wrong.

`install.ps1` copies the two scripts and registers the task. It needs no network
access. Earlier versions downloaded a 16MB `lg-input-switch.exe` from a pinned
release; installing now deletes that binary if a previous install left one behind.

Log: `%LOCALAPPDATA%\trigger-kvm\trigger-kvm.log`, rotated by the watcher at
startup once it passes 1MB (`-MaxLogBytes`), keeping one generation as `.log.1`.

## Triggers

**Anything that can run `trigger-kvm.ps1 pull` is a trigger.** The watcher and the
switcher are separate processes and that command line is the entire interface
between them, so a hotkey binding, a Stream Deck button, a scheduled task, or an
SSH command all work today with no support from this tool.

What ships is one trigger: `event-watch.ps1`, which fires on **device presence** and
is what `install.ps1` registers. There is deliberately no plugin system or trigger
registry — the process boundary already is one, and a second abstraction on top
would earn nothing.

**Verified end to end on hardware, 2026-08-30.** With the AirPods paired but
disconnected the watcher armed with `0 already present` -- the case a PnP check
would have got wrong -- and connecting them produced:

```
arrival bt:0011223344ff; settling 0.75s
fired: nvapi-probe.ps1 TEST (pid 17016)
```

Connection detected, edge recognised, settle honoured, switcher invoked.

**Two transports, one list.** USB device presence and Bluetooth *connection* are
both sources in the same process. The config takes one device list and the transport
rides on each value:

```
trigger.device = usb:046d:0843, usb:1235:820a, bt:0011223344ff
```

`usb:VVVV:PPPP` is a vendor+product pair; a **bare** `VVVV:PPPP` also means usb, so
configs written before Bluetooth existed keep working. `bt:AAAAAAAAAAAA` is a
12-hex-digit Bluetooth address. Anything else is rejected loudly at startup rather
than ignored.

The transport is in the value rather than in separate keys because the installer
presents **one** device list — you think "the stuff that moves when I switch", not
"my USB things and separately my Bluetooth things" — and the transport is metadata
it detects for you.

**Bluetooth matches on CONNECTED, never on paired**, and that distinction is the
whole reason it needs its own code path. A paired device keeps its PnP node for
*years* after it last connected — measured here, AirPods reading `Present=True` ten
months after the fact — so a PnP-presence check would never see an edge and the
trigger would silently never fire. The connection state comes from the classic
Win32 `bthprops.cpl` API by P/Invoke, whose `BLUETOOTH_DEVICE_INFO.fConnected` is
distinct from `fRemembered`.

It needs no new event plumbing: `Win32_DeviceChangeEvent` fires on Bluetooth
connect and disconnect (verified, both edges), so a Bluetooth device is evaluated on
the subscription that already exists. Note the volume difference if you ever tune
timings — a USB plug produces ~32 events, a Bluetooth connect about 3.

The Bluetooth list is enumerated once per presence sweep rather than once per
device, because the API walks the whole paired set on each call and a single USB
plug triggers dozens of sweeps. If the radio is missing or disabled, Bluetooth reads
as "nothing connected" and the USB half carries on — an absence never fires.

The config keys stay flat anyway — `trigger.device`, `trigger.debounce`,
`trigger.settle`. Nesting them under a transport was tried and reverted: it
advertised a capability that does not exist, and a malformed id already fails loudly
(`expected VVVV:PPPP`), so there was no silent failure for the extra structure to
prevent. When a second transport actually lands, that is the moment to decide how
ids get qualified — and the installer already warns rather than silently reverting
when it meets a key name it doesn't know.

The timings sit at `trigger.*` rather than under any transport for a reason that
does matter: **one debounce has to cover every trigger.** Two independent windows
could not dedupe against each other — the same failure that forced the
single-instance mutex to become machine-wide. At this level that holds by
construction, with no level at which a second one could be written.

**A trigger runs `pull`, and only `pull`.** Never wire one to another machine's
name. A name like `mac` describes inputs on hardware this machine cannot observe,
which go stale the moment someone moves a cable over there; keeping those names out
of the trigger path means a stale one can only ever spoil a command you typed and
are watching.

## Discovery

```powershell
trigger-kvm discover         # what's attached, in the form the config wants
trigger-kvm list             # just the displays
```

`discover` lists connected displays with their EDID ids, and devices attached or
connected **right now** — which is the filter doing most of the work, since you install on the
machine currently holding the peripherals, so whatever moves is by definition
present. Hubs and host controllers are dropped, and the several PnP nodes one
physical device produces are collapsed to one row per `VID:PID`, keeping the
best-named entry.

Bluetooth rows list every **paired** device, connected or not, each labelled with
which it is. The first version filtered to connected-only by analogy with USB, and
that was backwards: a trigger fires on *arrival*, so the device that is
disconnected right now is precisely the one that will produce one — the headphones
sitting on the Mac connect to this PC when you flip the switch. Hiding them hid the
choice a user most wants. Connected-vs-paired is still shown, because it is useful
context; it is just not a filter.

The Bluetooth **radio** is dropped from the USB rows along with hubs: it is
soldered to this machine and can never travel. So is a device whose enumeration
failed (vendor id `0000`), which has no address to match on.

It deliberately still shows your keyboard and mouse. They share a vendor id with the
webcam on this desk, and seeing that is how you avoid the vendor-only match that
would fire constantly.

## Configuration

`%LOCALAPPDATA%\trigger-kvm\config` — generated by `install.ps1`, **safe to edit by
hand**, and never overwritten by re-running the installer. It sits beside the log
rather than in the program directory so uninstalling doesn't throw away a
configuration you spent time getting right.

```
display.lg.vendor  = 0x1E6D     # EDID manufacturer id
display.lg.product = 0x9E9D     # EDID product id
display.lg.name    = LG 45GX950A
display.lg.method  = lg-alt     # standard | lg-alt

computer.this          = pc      # what this computer is called below
display.lg.input.0xD0 = pc      # the WHOLE map: which computer is on which input
display.lg.input.0xD1 = mac

trigger.device   = usb:046d:0843, usb:1235:820a, bt:0011223344ff
trigger.debounce = 3.0          # applies to every trigger, not per transport
trigger.settle   = 0.75
```

Flat `key = value` with `#` comments, deliberately not TOML or JSON: this is read on
every device arrival and must not depend on a parser being present. The whole reader
is a dozen lines, and the macOS side can do the same job with one `sed`.

**Which edits take effect when.** Display changes apply at the next
switch, because the switcher reads the file each time. Trigger changes need
`install.ps1` re-run — those are baked into the scheduled task at registration, and
the installer reads them back out of the config rather than from its own defaults.

**It fails closed, in ways worth knowing:**

- An unparseable EDID id refuses rather than defaulting. `[int]$null` is `0` in
  PowerShell, so a typo'd vendor would otherwise become a silent match against
  `0x0000` — a write aimed at the wrong panel is the failure this project spends
  most of its effort avoiding.
- A computer that two displays know about and a third does not moves **none** of them.
  Every value is resolved before anything is sent. A half-applied arrangement is
  worse than none: it leaves the desk in a state nobody configured, and you have to
  work out which half landed.
- `method = lg-alt` grants nothing. `NvDdc.WriteLgInput` still refuses any panel
  whose EDID manufacturer is not GSM, so putting `lg-alt` on a Dell makes the write
  throw — it does not make it happen. Verified by test.

## Manual use

```powershell
.\trigger-kvm.ps1 pull               # pull every configured monitor here
.\trigger-kvm.ps1 to mac             # point them at the computer called "mac"
.\trigger-kvm.ps1 pull -Only asus    # one monitor only
.\trigger-kvm.ps1 pull -WhatIf       # resolve and print packets, send nothing
```

`-Only <label>` takes a label from your config and exists because moving every
monitor at once can take away the display your terminal is on. Use it when testing.

`pull` and `to` are the **same lookup** against the same map, differing only in
which name they look up: `pull` asks for `computer.this`, `to mac` asks for `mac`.
There is no second table, so the two can never disagree about where a computer is.

They stay separate *verbs* on purpose, and that separation is a safety property
rather than a style choice. `computer.this` describes inputs on hardware this
computer is plugged into and can therefore be sure of. Any other name describes
inputs on hardware it cannot observe, which go stale the moment someone moves a
cable over there. **The trigger can only ever run `pull`**, so a name that has gone
stale can spoil a command you typed and are watching, never an automatic switch.

That is also why `display.<label>.self` and `scene.*` are both gone. They were two
different shapes for one fact — "computer C is on input V of display D" — and two
representations of the same fact can disagree. A mixed arrangement is a
composition, not a stored object: `trigger-kvm to mac -Only lg`.

## Verified behaviour

All four cases tested from Windows and confirmed visually on 2026-08-30, plus the
end-to-end USB trigger:

| Case | Method | From an inactive link |
|---|---|---|
| ASUS -> HDMI 1 (pull here) | NVAPI I2C, src `0x51` VCP `0x60 = 0x11`, aimed | yes |
| ASUS -> DisplayPort (push to Mac) | NVAPI I2C, src `0x51` VCP `0x60 = 0x0F`, aimed | n/a (was active) |
| LG -> DisplayPort (pull here) | NVAPI I2C, src `0x50` VCP `0xF4 = 0xD0`, aimed | yes |
| LG -> USB-C (push to Mac) | NVAPI I2C, src `0x50` VCP `0xF4 = 0xD1`, aimed | n/a (was active) |

Both "pull here" cases were exercised with the monitor **displaying the Mac**, which
is the case the whole design depends on: the machine issuing the command is by
definition not the one being shown. Windows keeps its link enumerated while the
panel shows the other machine, exactly as macOS does.

All four rows were re-verified on the aimed NVAPI transport on 2026-08-30, both
monitors, both directions, confirmed visually -- including both pull-backs from an
inactive link. The ASUS pull-back is the one that had never been done this way:
HDMI DDC over NVAPI rather than `dxva2`.

**Answering the open question this file used to carry:** yes, the ASUS answers DDC
over this PC's HDMI cable, including while it is displaying its DisplayPort input.
Only its DP input had been exercised from the Mac side; HDMI 1 is now confirmed.

**Hibernate (S4) disturbs neither monitor and fires no spurious switch.** Verified
2026-08-30 across a real `shutdown -h` / resume cycle, with both panels confirmed
visually. **S3 standby hangs this machine and must not be tested** -- that, and why
the watcher is safe across a power transition, is in [`../AGENTS.md`](../AGENTS.md).

**The LG flickers briefly on every LG switch, including a no-op re-assert to the
input it is already on.** It is re-negotiating the link, and each write is sent
twice on purpose. Normal, not a fault. The ASUS no longer receives that write at
all: it is aimed at the LG's output alone.

## Components

**`trigger-kvm.ps1`** -- sends both writes, through one transport. Each write is
sent twice: DDC is lossy and the writes are idempotent. There are deliberately no
reads anywhere in it.

`Resolve-Panel` enumerates the GPU's connected outputs, reads each EDID, and keeps
the one whose vendor and product identify the wanted panel. It refuses on zero
matches and on more than one, because an ambiguous target cannot be aimed at, and
picking the first would reintroduce the order-dependence this repo's conventions
forbid. `Switch-Asus` and `Switch-Lg` are four lines each: resolve, describe, hand a
write to the shared `Invoke-Switch`.

The Windows display list is deliberately not consulted for that identity. In session
0 `user32` reports a *phantom* monitor rather than none, so correlating against it
matches a fiction; NVAPI is the sole source. See [`../AGENTS.md`](../AGENTS.md).
That is also why there is no `dxva2` or `user32` code here any more, and why this
script has **no desktop dependency** -- the precondition for a pre-login tier.

The `Add-Type` block is loaded once per process and stamped with a hash of its own
source. Re-running the same version in one PowerShell session reuses what is loaded;
running a *different* version refuses with an instruction to open a new shell. .NET
cannot replace a loaded type, and silently reusing the old one would mean
hand-verifying code that is not the code on disk -- the worst outcome available when
hand-verification is the only verification this hardware permits (hard rule 3). The
installed path never reaches this: the task starts a fresh `powershell.exe` per
switch.

`Test-LgBlastRadius` is gone, along with the `$LG_KNOWN_OUTPUTS` list it enforced.
It existed only because `lg-input-switch` sprayed VCP `0xF4` at every connected
output, which made an unrecognised panel a real hazard and made attaching a third
monitor stop LG switching. An aimed write has no blast radius, so both the guard and
that side effect are gone.

What replaces it is narrower and stronger, and lives at the transport rather than
the call site: `NvDdc.WriteLgInput` is the only function that can emit I2C source
`0x50`, the source byte is not a parameter, and it **throws** unless the target's
EDID manufacturer is GSM (`0x1E6D`). The sidechannel cannot be aimed at another
vendor's panel by any caller. See [`../AGENTS.md`](../AGENTS.md) hard rule 5.

Use `-WhatIf` to resolve the panels and print the exact packet bytes without sending
anything:

```powershell
.\trigger-kvm.ps1 pull -Only lg -WhatIf
```

**Single instance is enforced machine-wide, not per session.** `event-watch.ps1` takes
`Global\trigger-kvm-usb-watch`. `Local\` would be scoped to one session, so a
logon watcher in session 1 and an at-startup watcher in session 0 would each take
their own, both arm, and both fire on the same arrival -- and the debounce is
per-process, so it cannot dedupe across them. Measured 2026-08-30: an unelevated
interactive process can create a `Global\` mutex here, and a second process sees it
held. `Local\` remains a fallback for a token without `SeCreateGlobalPrivilege`. If
the global name exists but cannot be opened, the watcher stands down rather than
falling back -- something owns it under another identity, and falling back would
recreate the exact double-fire this prevents.

**`event-watch.ps1`** -- `Register-CimIndicationEvent` on `Win32_DeviceChangeEvent`,
an extrinsic WMI event, so there is no polling interval. That event does not say
*which* device changed, so each one is followed by a targeted `Win32_PnPEntity`
query (~40ms) to establish identity. Push latency, exact identity, no elevation.

Three safety behaviours, ported from `../macos/usb-watch.c`:

- **debounce** (3.0s) -- ignore arrivals within N seconds of the last fire. This is
  not theoretical: on the first live test the Focusrite arrived at `01:49:46` and
  fired, and the webcam followed moments later and was correctly swallowed.
- **settle** (0.75s) -- after an arrival, wait, then confirm the device is *still*
  present. Appear-then-vanish was a glitch, not a switch.
- **edge-triggered** -- fires only on absent -> present. Devices already plugged in
  at startup never fire.

**`install.ps1`** -- Scheduled Task at logon, interactive session, `RunLevel
Limited`. Explicitly clears `StopIfGoingOnBatteries`, which defaults on and would
otherwise kill the watcher on a brief UPS blip.

## How it runs, and why it is hard to close by accident

There is **no window anywhere** -- no console, no taskbar entry, nothing to click.
Three separate mechanisms, because each covers a different failure:

**No console is ever allocated.** The task's action is `wscript.exe launcher.vbs`,
not `powershell.exe`. PowerShell is a console-subsystem binary: Windows gives it a
console *before* `-WindowStyle Hidden` can take effect, so running it straight from
a logon task can flash a console at every login and leaves a closeable window.
`wscript.exe` is GUI-subsystem and starts the watcher hidden from the first
instruction. `launcher.vbs` is generated by `install.ps1`, the same way the macOS
`Makefile` generates the LaunchAgent plist -- don't edit it, re-run the installer.

The launcher waits on the watcher rather than returning, so Task Scheduler still
reports the task as `Running` and its restart-on-failure settings still apply.

**It comes back if it dies.** `-AtLogOn` alone means that if the watcher is ever
killed -- Task Manager, a crash, a stray `Stop-Process` -- it stays dead until the
next logon, and you would only discover it when the displays quietly stopped
following the USB switch. A second trigger re-runs the task every minute;
`MultipleInstances IgnoreNew` makes that a no-op while it is alive, so the
steady-state cost is a process launch that exits immediately.

That no-op is also why `install.ps1 -Status` shows a last-run result of
`2147946720` / `0x800710E0` -- "The operator or administrator has refused the
request" -- during **normal** operation. It is Task Scheduler's code for a trigger
that fired while an instance was already running, i.e. `IgnoreNew` doing its job.
Expect it whenever the watcher is healthy; it is not a failure to chase.

That trigger is the *only* thing that brings it back. The task's `RestartCount` /
`RestartInterval` settings do not: killing the watcher leaves the task `Ready`
rather than failed, and no restart occurred in 180s of watching. Measured
2026-08-30, kill to running again: **51s** at a 1-minute interval, against 205s
when the interval was 5 minutes.

This is the one place Windows is meaningfully behind macOS, where launchd's
`KeepAlive` respawns in **0.01s** -- measured 2026-08-30 by `kill -9` on the
watcher, not estimated. The gap against this side's 51s is four orders of
magnitude, though both are recoveries from a failure that should not happen. Closing that fully would mean making
`launcher.vbs` a supervising loop, which is deliberately not done: stopping the
task kills the launcher but leaves the watcher (see below), so a loop would spin
relaunching a watcher that exits immediately on the mutex. A minute of downtime
after an unobserved failure is the better trade.

**Only one ever runs.** `event-watch.ps1` holds a named mutex
(`Local\trigger-kvm-usb-watch`) and exits immediately if another instance has
it. This matters more than it looks: the watcher is a *grandchild* of the task, so
stopping the task kills the launcher but leaves the watcher running. Without the
mutex, every reinstall and every self-heal tick would stack another watcher, and
each one would fire the switcher on the same arrival -- the debounce is per-process
and cannot dedupe across them. `install.ps1` also explicitly clears stale watchers,
so an upgrade cannot leave the old code holding the mutex.

A consequence worth knowing when testing by hand: running `event-watch.ps1` yourself
while the task is running will exit at once with `another usb-watch is already
running`. Stop the task first.

Both scripts also take `-LogFile` and append to it themselves, so nothing depends
on shell redirection -- which is what let the `cmd.exe` wrapper go away.

To stop it deliberately:

```powershell
.\install.ps1 -Uninstall     # unregister the task and clear any running watcher
Stop-ScheduledTask -TaskName trigger-kvm   # just this session; self-heal will restart it
```

## Watched devices

Kept in sync with [`../displays.toml`](../displays.toml):

| Device | ID | Note |
|---|---|---|
| Logitech Webcam C930e | `046d:0843` | Preferred anchor -- a UVC camera rarely re-enumerates spuriously |
| Focusrite Clarett+ 2Pre | `1235:820a` | Weaker anchor -- audio interfaces re-enumerate on driver reloads and power events |

Both confirmed present on this machine when the USB switch is pointed here.

**Match the full VID+PID, never the vendor alone.** The keyboard and mouse are
Logitech too (`VID_046D`, `PID_C547`) and are *always* present, because they are
wired directly to this PC's motherboard and do not pass through the USB switch. A
vendor-only match would fire continuously.

## Traps specific to Windows

**Do not address monitors by index or by description. The indices are not stable.**
They were `\\.\DISPLAY1` = ASUS and `\\.\DISPLAY2` = LG for all of this project's
early testing, and then on 2026-08-30 they **swapped**: the same
`trigger-kvm.ps1 windows` that had been logging `on \\.\DISPLAY1` for the ASUS
began logging `on \\.\DISPLAY2`, across a hard reboot and a hibernate cycle.
Nothing broke, because the script never uses the index. Getting this wrong would
send LG service-channel writes to the ASUS.

**Both panels are resolved by the EDID that NVAPI reads off the GPU output** --
manufacturer and product, compared against the values in `../displays.toml`. That is
aimable, stable, and works with no desktop.

Two identity mechanisms that were tried and are *not* used, each for a specific
reason worth not rediscovering:

- **`\\.\DISPLAYn` indices** -- not stable, as above.
- **The dxva2 description string** -- useless as a key: it reports the LG as the
  generic `Generic PnP Monitor`.

The PnP interface path (`\\?\DISPLAY#AUS42E0#...`) *does* carry the EDID id and was
what the ASUS matched on until 2026-08-30. It works, but only with a desktop, so it
went when the ASUS moved onto NVAPI.

**Historical:** `lg-input-switch` was not addressable to one monitor -- it injected
on every connected output, so the ASUS also received the LG's VCP `0xF4` write. That
was confirmed harmless on the PG42UQ, once with the ASUS's own write isolated out
(`-Only lg`), which is the only way to attribute a flicker to the spray rather than
to the ASUS re-asserting its own input. That measurement is the sole evidence anyone
has about `0xF4` on a PG42UQ, which is why it is kept -- but nothing depends on it
now that the write is aimed.

**Keep `.ps1` files ASCII-only.** Windows PowerShell 5.1 reads a `.ps1` without a
BOM as ANSI, so a UTF-8 em dash in a comment becomes a parse error tens of lines
away from anything that looks wrong.

## Scope: post-login only

The task runs at logon in the interactive session, matching macOS. A Windows
Service would run in session 0, which has no desktop, so
`GetPhysicalMonitorsFromHMONITOR` would have no `HMONITOR` to work from. NVAPI
display enumeration in session 0 is untested and expected to be problematic for the
same reason. See [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

## `nvapi-probe.ps1` -- a read-only diagnostic

```powershell
.\nvapi-probe.ps1                              # print what NVAPI can see
.\nvapi-probe.ps1 -LogFile C:\ProgramData\trigger-kvm\nvapi-probe.log
```

Enumerates GPUs, connected displays and each display's EDID **through NVAPI only**,
and prints a `user32 EnumDisplayMonitors` count beside it as a control. It exists to
answer whether monitors can be identified in a context that has no desktop, which is
the precondition for any pre-login work.

**It performs no writes.** `NvAPI_I2CWrite` is deliberately not resolved anywhere in
the file, so it cannot be called even by accident; nothing is sent to source address
`0x50`; no VCP value is read or written. `NvAPI_GPU_GetEDID` reads the EDID block
from the GPU, which is neither the service channel nor a VCP read. Safe to run
repeatedly, in any context, with nothing to confirm visually.

Function ids and struct layouts come from [SimpleKVM](https://github.com/fiddyschmitt/SimpleKVM)
(MIT), with `NvAPI_Initialize` and `NvAPI_EnumPhysicalGPUs` independently
corroborated by `lg-input-switch`.

## Still open

- **Does NVAPI work from a context with no desktop? YES, for enumeration.** Measured
  2026-08-30 in three contexts -- interactive, SYSTEM in session 0, and an unelevated
  non-interactive S4U task. All three enumerated both panels with correct EDIDs and
  **per-output ids** (ASUS `0x100`, LG `0x200`) -- the aiming `lg-input-switch` threw
  away, and what the LG path now uses. Re-confirmed at boot from an at-startup task.
  In session 0, `user32` meanwhile reported one *phantom* monitor -- see
  [`../AGENTS.md`](../AGENTS.md).
- **Does the ASUS answer on the same NVAPI transport (src `0x51`, VCP `0x60`)? YES.**
  Verified visually 2026-08-30, both directions, including the pull-back from an
  inactive link. That collapsed the two identity mechanisms into one and removed the
  last `dxva2` dependency, so the switcher no longer needs a desktop at all.
- **Does a WRITE work from session 0? YES.** Measured 2026-08-30 from an unelevated
  on-demand S4U task (`sessionId=0 interactive=False`): it pushed the LG to the Mac,
  held 12s, and pulled it back, **both moves confirmed visually**. Enumeration
  working there did not imply this, and the two had to be tested separately -- phase
  1 deliberately sent no writes. This settles the pre-login design: a plain
  at-startup task drives the displays directly, with no relay.
- **Do WMI device notifications reach a session-0 watcher? YES.** Measured
  2026-08-30 from an unelevated S4U task (`sessionId=0 interactive=False`): 45
  `Win32_DeviceChangeEvent` indications received in 90s, and `Win32_PnPEntity`
  presence queries returned correct results there too. This was the last thing that
  could have made the s4u tier fail *silently* -- the switcher was already proven in
  session 0, but the detector was not, and a watcher that runs and never fires is
  the worst failure shape available. The distinction that made it plausible either
  way: `WM_DEVICECHANGE` is a window message and needs a desktop, while
  `Win32_DeviceChangeEvent` is a WMI extrinsic event from the Winmgmt service. Only
  the latter is used here, and it is session-independent.
- **Does a pre-login tier get built?** Built as opt-in -- `trigger-kvm configure`,
  `Autostart?`, `From boot`. There is no `-Tier` flag: the tier lives in the config
  as `install.autostart`, and every part of the installer reads it from there. The remaining
  step is a reboot acceptance test. It is a permissions question rather than a
  technical one. It needs admin to register (measured: `S4U` and `SYSTEM`
  principals both fail with "Access is denied" for an ordinary user, while the
  `Interactive` task this installer uses does not). That changes the project's
  current "no admin needed" posture, so it is a deliberate call, not a default.
  `S4U` is the tier to prefer: admin once to register, then ordinary user rights at
  runtime, and no elevated code on the switch path.
- **Note what it would actually add. Locking is already covered.** Confirmed
  2026-08-30: with the screen locked, flipping the USB switch still pulls the
  displays back, because the session and its watcher are still alive. A pre-login
  tier buys the two narrower cases -- **before the first login after a boot** and
  **after a full logoff**. The first is the one that stings: a rebooted PC sitting at
  a login screen you cannot see, because the monitors are still showing the Mac.
