# macOS: what to build, and what it has to match

The Windows side is finished and in daily use. The Mac side is a 87-line script with
two monitors and their input values hardcoded in it. This document is the
specification for closing that gap.

**Read this as a contract, not a suggestion.** Almost everything below was arrived at
by getting it wrong first, on real hardware, and the comments in
`windows/install.ps1` and `windows/trigger-kvm.ps1` record which. Where this document
says "must", it is because the alternative has already been tried.

Two files are the source of truth and this one only points at them:

- `displays.toml` — the measured values, shared by both platforms.
- `AGENTS.md` — the hard rules. They are not Windows rules; they are hardware rules.

## 0. What exists today

```
macos/
  trigger-kvm.sh    two monitors and four input values, hardcoded. No config, no
                    verbs but `mac` and `windows`, no installer, no discovery.
  usb-watch.c       a presence watcher, still USB-only
  Makefile, README.md
```

`macos/trigger-kvm.sh` **cannot read a config this repo writes**. It looks for values
that no longer exist. Treat it as a proof that the transport works, not as a base to
extend.

## 1. The hard rules

Copied here because a macOS implementation will be tempted by each of them.

1. **Never probe a manufacturer sidechannel.** The LG's input lives on I2C source
   `0x50`, VCP `0xF4` — a service channel. `ddcutil` carries an issue titled "Bricked
   LG Monitor". Values for a sidechannel come from the dialect table or from a value
   the user typed. Never from a search, a sweep, or a range.
1b. **A manufacturer dialect is OFFERED, never probed, and only after standard DDC/CI
   has been shown not to work.** Every panel starts on standard.
2. **Never verify a switch by reading a VCP value back.** Reads lie on both panels
   here — the PG42UQ returns `0` for everything always, the LG returns `-7` on an
   unsettled link. Writes are fire-and-forget. No verify-then-retry loops.
3. **A switch is confirmed by a human looking at it.** Never report success because a
   call returned 0.
4. **Never leave the user without a working display.** One panel at a time; never the
   last one.
5. **Refuse rather than send an unresolved value.** Resolve every display before
   sending anything. This one bit hardest: a missing value became `0x00` on the wire,
   an input no monitor has, so every switch silently did nothing. The null check was
   present and did not fire. Assert the property — *nothing is sent* — not the check.

## 2. The config format — normative

Flat `key = value`, `#` comments, deliberately not TOML or JSON: it is read on every
device arrival and must not need a parser. Keys are lower-cased on read; values are
returned verbatim and trimmed. In shell that is one `sed`.

```
install.autostart = boot          # boot | login | no

computer.this = mac               # what THIS computer is called below

display.lg.vendor  = 0x1E6D       # EDID manufacturer id
display.lg.product = 0x9E9D       # EDID product id
display.lg.name    = LG ULTRAGEAR+
display.lg.method  = lg-alt       # standard | lg-alt
display.lg.input.0xD0 = pc        # which computer is on which input
display.lg.input.0xD1 = mac

trigger.device   = usb:046d:0843, bt:0011223344ff
trigger.debounce = 3.0
trigger.settle   = 0.75
```

**`display.<label>.input.<value> = <computer>` is the whole map.** There is no
second table. `pull` looks up `computer.this` in it; `to mac` looks up `mac`. The
same lookup, the same code path, one name apart — so the two can never disagree
about where a computer is.

Windows previously had `display.<label>.self` *and* `scene.<name>.<label>`, which
were two shapes for one fact ("computer C is on input V of display D"). They could
drift, and did. **Do not reintroduce a second table.**

Rules the reader must enforce:

- A value that does not parse as a byte is dropped, not zeroed.
- Two inputs naming the same computer on one panel is a **refusal**, not a coin toss.
- A computer named on no input of a panel means that panel cannot go there — and a
  `to` naming it must move **nothing at all**, not the panels that could.

## 3. The CLI — the verbs are the contract

One command. Flags stay idiomatic per platform (`-Only` on Windows,
`--only` on macOS is fine); the **verbs must be identical**, because they are typed
daily on both machines.

```
trigger-kvm pull                 point every configured monitor at THIS computer
trigger-kvm to <computer>        point them at another, by name. MANUAL ONLY
trigger-kvm list                 connected displays, with their identifiers
trigger-kvm configure            the walkthrough (§5)
trigger-kvm configure --fresh    ...pre-filling nothing
trigger-kvm status               autostart, what that covers, version, config
trigger-kvm discover             what is attached, in the form the config wants
trigger-kvm restart              make a hand-edited config take effect now
trigger-kvm logs                 tail the log
trigger-kvm pause                stand the watcher down to test by hand
trigger-kvm uninstall
```

**There is no `install` verb**, deliberately: installing is what produced the
command. Upgrading and repairing both mean "fetch the source and run its installer",
which works because the install is self-contained — the installer copies itself, so
managing and removing keep working after the source tree is gone.

**There is no `apply` step.** Everything is read at the point it is used. Display
edits take effect on the next switch; trigger edits when the watcher next starts, and
`restart` does that.

`set --only <label> --value <byte>` exists as an internal verb for the walkthrough's
guided discovery. Keep it off the public verb surface: a general "write any value"
command invites poking at monitors, which is the habit rule 1 exists to discourage.

### Why `pull` and `to` are separate verbs

Not style. `computer.this` describes inputs on hardware this computer is plugged into
and can be sure of. Any other name describes inputs on hardware it **cannot observe**,
which go stale the moment someone moves a cable over there. **The trigger may only
ever run `pull`** — so a stale name can spoil a command you typed and are watching,
never an automatic switch.

## 4. The switcher

Identity comes from the EDID the GPU read off the output, never from an index.
`\\.\DISPLAYn` numbers are not stable on Windows and have swapped; m1ddc's index
numbers shift when a display drops. **Resolve by EDID vendor+product**, and note that
the LG reports a *different product id per input* (`0x9E9D` on DP, `0x9E9F` on USB-C)
— so a product id is a local key, never something to copy between hosts.

Two methods, one transport concept:

| method | I2C source | VCP | when |
|---|---|---|---|
| `standard` | `0x51` | `0x60` | nearly every panel |
| `lg-alt` | `0x50` | `0xF4` | LG panels whose standard input control is stubbed |

On macOS `m1ddc` exposes these as `set input` and `set input-alt`. If you move to
IOAVService directly, the packet is
`[source, 0x84, 0x03, vcp, 0x00, value, checksum]` with checksum = `0x6E` XOR every
preceding byte — the same bytes `displays.toml` documents.

**The sidechannel must be unreachable by construction.** On Windows the source byte
`0x50` appears in exactly one function, which refuses any target whose EDID
manufacturer is not GSM, and is not a parameter of any public method. Setting
`method = lg-alt` on a non-LG panel makes the write *throw*; it does not make the
write happen. Build the macOS equivalent the same way — a gate a caller cannot pass
around, not a check a caller is asked to perform.

Resolve-before-send, and DDC is lossy so a repeat write is free (Windows sends once
and logs; macOS currently sends twice — either is fine, but do not *read* to decide).

## 5. The installer and walkthrough — the part to match closely

This is what the user asked to be "almost identical", and it is the bulk of the work.
Windows arrived at this shape over many iterations; the reasoning for each is in the
comments at the point of use.

### 5.1 The menu primitives

Everything is one of two menus, and **enter does what the highlighted row says**.

`Select-One` — one choice, returns an index:

```
   1) DisplayPort 1                0x0F
   2) DisplayPort 2                0x10
   -- HDMI 1                       0x11   assigned to pc
   4) HDMI 2                       0x12
 > 5) Type a value...

  up/down move   enter choose   esc back
```

- **Detail column.** Item on the left, its value on the right. The item column is 28
  wide, or the longest item + 1, capped at 44.
- **Wrapping, never truncation.** A long detail wraps at the `", "` between items onto
  continuation lines aligned under the column. Truncating hid the very values the
  review screen exists to let someone check. An unbreakable single item overruns
  rather than being cut.
- **Separators.** An empty item draws a blank line, is skipped by the cursor and
  cannot be chosen. Used to group a long menu.
- **Disabled rows.** Drawn, annotated, skipped by the cursor, unpickable — an input
  already assigned to another computer. Hiding it would make the list change shape as
  you answer; renaming it would lose the only label the monitor's own menu agrees
  with.
- **`(current)`** marks whatever is configured now. Starting the cursor there is not
  enough: the cursor also means "where you are", so a re-run gave no way to tell an
  unchanged default from a deliberate choice.
- **Esc goes back**, opt-in per menu, meaning "back, and change nothing". Not offered
  on the top menu (it has Cancel, and a setup should not be discarded by a stray
  keypress) nor on a question that must be answered.

`Select-Many` — several choices:

```
  > [x] usb:046d:0843    USB   Logitech Webcam C930e
    [ ] bt:0011223344ff  BT    AirPods Pro  (paired, not connected)
    [x] usb:1235:820a    USB   Clarett+ 2Pre

        Done                     2 selected

  up/down move   enter toggles the highlighted row   esc back
```

- **Enter toggles the highlighted row.** There is no accept key — there is a `Done`
  row you move to. "Space toggles, enter accepts" lost people immediately: enter is
  what you press, so the first thing it did was accept an empty list.
- Space toggles too, for anyone who reaches for it.
- Enter on `Done` with nothing checked **refuses** and says so.
- `Done` is a plain row aligned with the item text, with a live count in the detail
  column. It was a bracketed button for a while; every other menu ends with a bare
  `Done`, so the brackets read as inconsistency.

**Both must fall back to typed input** when the host cannot read individual keys — a
redirected stdin, a non-console host, a remote session that does not forward keys.
This is not a nicety: it is what makes the whole flow testable end to end (§6), and
`q` is the fallback's `esc`.

### 5.2 The menu IS the flow

There is no separate first-run questionnaire. An empty install is the same menu with
`not set` in it and the cursor already on the first thing that needs an answer.
Finishing a section returns here with the cursor on the next unanswered one.

```
--- configuration ---

 > 1) Computers                    not set
   2) Monitors                     not set
   3) Triggers                     not set
   4) Autostart?                   not set
   5) Add to PATH?                 not set

   7) Test the monitor inputs      untested
   8) Test the triggers            untested

  10) Save configuration and run
  11) Cancel (discard changes)
```

- **Nothing is preset.** Autostart and PATH have obvious answers, but the suggestion
  belongs on the highlighted row *inside* their menu, not in the value column of a
  menu nobody has opened. One of those answers asks for admin; the other edits a PATH.
- **Nothing is written until Save**, so an interrupted run leaves a working setup
  untouched. Save **refuses** while a required section is `not set`, naming what is
  missing: writing half a setup produces a config the switcher then declines to act
  on, which is a worse way to find out.
- Where the cursor lands is the recommendation: unanswered sections in order, then
  the checks in order, then Save. A failed check sends the cursor to the setting that
  failed, not onward.
- The header reads `--- configuration ---` until monitors and triggers are set, then
  `--- review configuration ---`.

**One punctuation rule down the value column**, because it is read as a column:
`", "` separates items, `": "` separates a label from its value, `"/"` joins things
sharing one label. Not cosmetic — the wrapper breaks at `", "`, so a row using
anything else cannot wrap.

### 5.3 Computers — asked before the monitors

Asked first so a computer is described once rather than once per screen, and so every
panel then offers the same names.

```
--- computers ---
These monitors are shared between this computer and some others.
Each one gets a name, and the name is how you switch to it:
    trigger-kvm to mac

  What should I call THIS computer? [mac-studio]
  How many OTHER computers are plugged into these monitors? [1]
  What is the other one called?

   1) mac                          this computer
   2) pc

   4) Add another computer
   5) Done
```

- First run asks for a **count**, then that many names. "One per line, blank line
  when there are no more" made people guess both how to finish and whether a blank
  meant cancel.
- Then, always, the list: picking a name **renames** it; entering nothing **removes**
  it; `Add another computer`; `Done`. A re-run goes straight to this list.
- **One name per computer**, not a slug plus a display name. The name is a config
  value, an argument you type, and a label in every prompt; a second field would be a
  second thing to keep in step for the sake of capital letters.
- **Character rule: lowercase letters, digits and dashes.** Spaces and dots become
  dashes; anything else is dropped. It must **suggest and ask**, never silently
  mangle — the first version stripped what it did not like, so "My Mac" quietly
  became "mymac".
- **A rename is carried into every panel's map**, a removal takes that computer out of
  them, an addition leaves them alone. Do not re-ask the monitors: that was tried and
  it threw away answers nobody asked to change.

### 5.4 Monitors — a list you pick from

```
--- monitors ---

  > LG ULTRAGEAR+                lg: mac/pc
    PG42UQ                       not managed

    Done
```

Picking one asks: manage it? → a short name → **for each computer, which input it is
on**. Machines-major, not inputs-major: a panel has eight possible inputs and two
real ones.

- The panel's own name comes from the **EDID monitor-name descriptor (tag `0xFC`)** —
  `PG42UQ`, `LG ULTRAGEAR+`. Asking the hardware beats a table, which only ever knows
  the monitors its author owned.
- The input list is the channel's own values **in the channel's own order**. A value
  someone typed that the channel does not list is *appended* so it can be shown, never
  inserted.
- An input already assigned is **disabled and annotated** (§5.1), because two
  computers cannot share a socket.
- `Not on this monitor` for every computer except this one; `Type a value...` always.

### 5.5 Autostart

```
--- should it start on its own? ---

 > 1) From boot (requires admin)
   2) From login
   3) No -- I will start it myself
```

From boot is offered **first and is the default**, because a computer sitting at a
login screen should still follow the switch; the cost is one admin prompt during
setup. An existing config still wins. A **headless** install falls back to login,
because it cannot ask — nothing elevates without someone choosing it.

macOS mapping, to be settled by whoever builds it:

| answer | Windows | macOS candidate |
|---|---|---|
| boot | Scheduled Task, S4U principal, RunLevel Limited | LaunchDaemon (root) — **but the switcher must not run as root**; see below |
| login | Scheduled Task, Interactive | LaunchAgent in `~/Library/LaunchAgents` |
| no | task registered with **no triggers**, started once | agent installed but not loaded; `restart` loads it |

The Windows boot tier runs **as the user, unelevated**, in session 0 — admin is
needed once to register, and nothing elevated runs on the switch path. Preserve that
property. A LaunchDaemon runs as root, which is not the same thing; if macOS has no
equivalent of "start before login as this user without their password", say so
plainly in `status` rather than pretending the tiers match.

### 5.6 PATH

Yes/no, with a suggestion. On Windows only a `bin/` directory holding a single
launcher goes on PATH — putting the whole install directory there would publish every
file in it as a command. Do the equivalent: one symlink, not a directory of scripts.

The row is **always drawn**, showing `already on PATH` and disabled when there is
nothing to decide. Omitting it moved every row below it and left the cursor
apparently skipping a step.

### 5.7 Checking the monitor inputs

What is under test is the claim that **input V of panel P is computer C** — a panel
that answers every command perfectly while its inputs are mapped to the wrong
computers fails this and is not broken. Hence "test the monitor **inputs**".

```
  Which monitor do you want to check?
 > 1) All of them
   2) LG ULTRAGEAR+
   3) PG42UQ
```

Then, **batched across panels, never across machines**. Monitors sit side by side, so
several are confirmed in one glance; a *sequence* over half a minute has to be held in
memory and reported afterwards, and memory is the weak link.

```
  Sending PG42UQ to pc for 8s, then back automatically.
  If pc is asleep or off you will see No Signal, which still proves the switch worked.

  LG ULTRAGEAR+ stays here, so you can read this.
  If this window is on PG42UQ, drag it to LG ULTRAGEAR+ first: if the switch back
  fails, the window goes dark with it and there is no way to answer.

  Enter when ready
```

- **Hard rule 4**: one panel always stays on this computer, so the question arrives on
  a screen that can be read. When every panel claims the target, that is two rounds.
- The warning is **said every round**, not asked once. An earlier version asked which
  monitor the window was on so it could schedule that panel last; that is a question
  about the tool's convenience, and people could not answer it confidently.
- "What stays" is measured against **every managed panel**, not just this round's — a
  panel nobody asked about is still somewhere to put a window.

One question per round, then narrowing only on failure:

```
  Did all of them show pc, then come back?  [Y/n]
  → n:  Which ones did not?   (multi-select)
```

Then, per failed panel, **two questions in the order it happened**:

```
  Did the LG ULTRAGEAR+ change to pc, and back to mac?
   1) Yes, and it changed back to mac         everything works
   2) Yes, but it did not change back to mac  the input for mac is wrong
   3) No

  (only on "No")
  Did the LG ULTRAGEAR+ change at all?
   1) Yes, but it was not pc      that input is not pc
   2) No, nothing happened        this panel does not answer on this channel
```

Four outcomes, four different repairs:

| outcome | meaning | repair |
|---|---|---|
| 0 | correct | next |
| 1 | showed the wrong computer | re-ask **that computer's** input, retry |
| 2 | did not come back | re-ask **this computer's** input, or walk for it, retry |
| 3 | nothing happened | offer the **manufacturer dialect**, or say nothing known reaches this panel |

One retry per fix, then take the answer. Do not loop.

**Blind value-walking is the last resort**: standard DDC only, MCCS values one at a
time, offered with its cost stated ("every wrong value moves that panel; if none is
right it stays there"), and **refused outright when it would take the last display**.

**One monitor is a special case and must be handled explicitly.** Nothing can be held
back, so if the switch back fails the person is looking at a black screen. That is
unavoidable; being stranded *without having been told how to get back* is not, and the
telling has to happen while there is still a screen to read it on:

```
  READ THIS FIRST -- this is your only monitor.
  You will not be able to read anything while it is away.

  IF IT DOES NOT COME BACK there is nothing this tool can do for you --
  it cannot draw on a screen that is showing another computer. The way
  back is the monitor itself: press its input (or source) button and
  choose HDMI 1, value 0x11. No software can take that button away from you.

  Ready? [Y/n]
```

Note the input is named **in the monitor's own words** — the OSD has never heard of
`pc`. Declining reads as **not checked**, never as a pass.

### 5.8 Checking the triggers

Checked **after** the monitor inputs, and that ordering is the point: once the input
values are confirmed, the flip *back* can pull the monitors for real, so it stops
being "an event was observed" and becomes the whole thing working end to end.

```
--- test the trigger ---
  Flip your switch AWAY from this computer, then back again. The way
  back is what a trigger is: the devices ARRIVING here.

  When they do, the monitors will be pulled here for real, using the
  values you just checked.
```

- The watcher gets a one-shot mode (`--test-trigger`) that prints current presence,
  waits for one **arrival**, reports it and exits. It takes **no lock and runs
  nothing**, so a real watcher may run alongside.
- On success, the installer runs `pull` **against a throwaway config** — the answers
  are not written yet, and the saved config would move the panels to whatever was
  configured before.
- Then: `Did the monitors come back to this computer?` A "no" there is a *monitors*
  fault with the trigger passing, which is a different diagnosis from "nothing
  arrived".
- Until the inputs are checked it reports the arrival and **moves nothing**, saying so.

### 5.9 The closing message

Short. It runs, here is how to see that, here are four commands.

```
  Done. trigger-kvm is running, and will start automatically each time you log in.

  Flip your switch to this computer -- the monitors should follow.

    trigger-kvm status      is it running?
    trigger-kvm pull        bring the displays here now
    trigger-kvm logs        what has it been doing
    trigger-kvm configure   change any of this
```

Everything else — how it starts, sessions, the transport — is in the docs for the day
someone needs it and is noise on the day they do not.

## 6. Authority -- decide these yourself, stop for those

You are expected to run this end to end without checking in. To make that possible,
here is where the line is.

**Decide yourself, and record the decision in a comment at the point of use:**

- Language and structure of the macOS side (shell, Swift, a mix). The verbs and the
  config are the contract; the implementation is not.
- Every wording choice not quoted verbatim in this document.
- File layout under `macos/`, function names, how the menus are drawn.
- Whether to shell out to `m1ddc` or bind IOAVService directly.
- How far to chase a trap that does not reproduce on macOS -- note it and move on.

**Stop and ask, every time:**

- Anything that would relax one of the five hard rules in §1. If a rule seems to block
  a feature, the feature is wrong until a human says otherwise.
- A change to the config format or the verb list. Both are cross-platform contracts,
  and changing one silently breaks the other machine.
- Sending any value to a monitor that is not in `displays.toml`, not in the dialect
  table, and not typed by the user in that moment.
- Anything needing `sudo` on the switch path, as opposed to once, at install.

**Never without being asked:** push to a remote, create branches, force-push, amend,
or install anything system-wide outside the documented install.

## 7. Definition of done

Each phase in §11 is finished when its line here passes. These are the acceptance
criteria; do not move on without them.

1. **Config + verbs.** `pull` and `to <computer>` build the exact packets in
   `displays.toml`, and a dry run prints them without sending. `to nosuch`, a panel
   with no inputs, an unparseable value and a missing `computer.this` each **refuse
   and send nothing**.

   Write the config by hand from §2 to get started — do not try to copy one off the
   Windows machine. A config is machine-local: `computer.this` differs, and the LG
   reports a **different product id per input**, so the id this Mac sees on its own
   cable is not the one the PC sees on its. This desk, from the Mac's side, is:

   ```
   computer.this = mac

   display.lg.vendor  = 0x1E6D
   display.lg.product = <read it -- `trigger-kvm list`, or 0x9E9F if USB-C>
   display.lg.name    = LG ULTRAGEAR+
   display.lg.method  = lg-alt
   display.lg.input.0xD1 = mac        # USB-C
   display.lg.input.0xD0 = pc         # DisplayPort

   display.asus.vendor  = 0x06B3
   display.asus.product = 0x42E0
   display.asus.name    = PG42UQ
   display.asus.method  = standard
   display.asus.input.0x0F = mac      # DisplayPort
   display.asus.input.0x11 = pc       # HDMI 1

   trigger.device   = usb:046d:0843, usb:1235:820a
   trigger.debounce = 3.0
   trigger.settle   = 0.75
   ```

   Those input values are measured and are in `displays.toml`. The product id is the
   one thing to read rather than copy.
2. **`discover`.** Every attached display with EDID vendor, product and the panel's
   own name; USB devices attached now; **every paired** Bluetooth device with its
   connected state shown but not filtered on.
3. **Watcher.** Survives ~32 events per plug without double-firing; refuses to start
   twice; returns within a minute of being killed; rotates its log; and its one-shot
   mode reports an arrival and exits without taking the lock.
4. **Menus.** Covered by tests: enter toggles, `Done` accepts and refuses when empty,
   separators and disabled rows are skipped, `(current)` marks the configured row,
   `esc` changes nothing, long details wrap and are never truncated. Every assertion
   mutation-checked.
5. **Walkthrough.** From no config, the menu alone produces a config identical in
   shape to the Windows one; a re-run opens with nothing to fill in; `--fresh` asks
   everything again; save refuses while a section is unset.
6. **Checks.** The input check batches across panels, always keeps one panel here,
   handles the single-monitor case with its recovery text, and the trigger check pulls
   for real only after the inputs pass.

A phase that cannot meet its line stops there and reports why -- see §6.

## 8. Testing — required, not optional

Windows has `windows/tests/`, seven files, run by `run.ps1`, no framework: a test is a
script that throws. Build the equivalent (`bats` is reasonable on macOS, or plain
`sh` + `set -e`), and hold to three properties that were each learned the hard way:

1. **Run with the same strictness as the scripts.** The PowerShell harness sets
   `Set-StrictMode -Version Latest` because the scripts do; without it, four crashes
   were invisible in tests and hit the user instead. The shell equivalent is
   `set -euo pipefail` plus `shellcheck`.
2. **Stub the one function that emits a packet**, so the suite cannot move a
   developer's monitors. Windows funnels every write through `Send-Input` for exactly
   this.
3. **Mutation-check.** A passing test proves nothing until it can fail. Reintroduce
   the bug and confirm the test catches it. One truncation test passed under mutation
   and had to be strengthened before it earned its place.

The walkthrough is driven by scripting the answers through the typed fallback — which
is the reason the fallback exists.

## 9. Decisions already made for you

These were open questions. They are not any more, because stopping on each would
defeat the point of this document. **Take the default; the fallback is what to do if
the default turns out not to hold on the hardware.**

| question | do this | if that fails |
|---|---|---|
| transport | shell out to `m1ddc` (`set input`, `set input-alt`) -- already proven on this hardware | bind IOAVService directly and build the §4 gate around the source byte |
| identity | read the EDID via IOKit (`IODisplayEDID`) for vendor+product | key on m1ddc's display **UUID**, and record in the config that the key is m1ddc-specific and not portable |
| the LG's per-input product id | match on **vendor + product**, and if the LG resolves under a different product id from the Mac, write THAT id into this Mac's config | never copy a product id between hosts; it is a local key |
| USB presence | IOKit `IOServiceMatching("IOUSBDevice")` with a notification port | poll every second; a fallback, not a design |
| Bluetooth presence | IOBluetooth paired devices, firing on `isConnected` | drop Bluetooth triggers for now and say so in `status` |
| autostart: login | a LaunchAgent in `~/Library/LaunchAgents`, `RunAtLoad` + `KeepAlive` | -- |
| autostart: boot | a LaunchDaemon runs as **root**, which is not the Windows property. If you cannot start before login **as the user**, make the row read `From boot (not available on macOS)` and disable it | never run the switcher as root to obtain the tier |
| autostart: no | install the agent but do not `launchctl load` it; `restart` loads it | -- |
| PATH | one symlink in `/usr/local/bin`, or `~/.local/bin` if that needs no sudo | -- |
| single instance | `flock` on a file under `~/Library/Application Support/trigger-kvm/` | a launchd label that cannot load twice |
| test framework | plain `sh`; a test is a script that exits non-zero | `bats`, if it is already present |

## 10. Traps the Windows build hit

Worth reading before repeating them:

- **A stale install is worse than no install.** Migrating a config to a shape the
  installed scripts cannot read made every switch send `0x00` — a real input on no
  monitor — so nothing moved and nothing said why. Never change the config format
  without reinstalling in the same breath.
- **`~32 USB events per plug.** Debounce is mandatory, and one window must cover every
  trigger: two independent windows cannot dedupe against each other.
- **The self-heal matters.** If the watcher is killed it stays dead until the next
  login unless something restarts it. Windows uses a 1-minute repeating trigger;
  launchd's `KeepAlive` does this properly and in about a second.
- **Do not "simplify" the Bluetooth path onto the USB one.** Three routes were tried
  and ruled out before P/Invoke to the classic API worked.
- **An abandoned lock is not an error.** A killed watcher leaves the lock held; the
  next one must take it over and say so, not exit.

## 11. Order of work

1. **Config reader + `pull`/`to`/`list`.** Make `trigger-kvm.sh` read a real config
   and drop the hardcoded values. This alone makes the Mac usable with a config this
   repo writes.
2. **`discover`** — displays by EDID, USB and Bluetooth candidates.
3. **The watcher**: config-driven, both transports, debounce, single-instance,
   self-heal, log rotation, `--test-trigger`.
4. **The menu primitives** (§5.1) plus their typed fallback, and the test harness
   around them. Everything after this depends on them.
5. **The walkthrough** (§5.2–5.6).
6. **The checks** (§5.7–5.8) — last, because they are the part that moves hardware.

Steps 1–3 make the Mac work. Steps 4–6 make it match.
