# `trigger-kvm configure` -- normative

The walkthrough: how a machine goes from nothing to a working setup, and how
every setting is changed afterwards. `configure --fresh` runs the same
walkthrough pre-filling nothing.

[`README.md`](README.md) says how normative wording is marked and enforced. The
hard safety rules this flow obeys are in [`../AGENTS.md`](../AGENTS.md).

---

## 1. What it is for

To produce a [config](config-format.md) that says **which computer is on which
input of which monitor**, and to prove it by moving the monitors while someone
watches. If a question does not change what gets written or what gets checked,
it is not asked.

## 2. Voice

Short sentences. Say the thing, then say why if the why is not obvious.

- Plain words: "monitor", not "panel" or "display device". `EDID` or `DDC/CI`
  only where the reader needs the term to look something up.
- **"computer", never "machine"**, everywhere the user can see it.
- **Name the consequence, not the mechanism**: "if the switch back fails, the
  window goes dark with it and there is no way to answer".
- No exclamation marks, no apology, no reassurance.
- Second person for what the reader does; first person only where the tool is
  the actor.

## 3. UI grammar

Every list question is one of two menus, and in both **enter does what the
highlighted row says**. A multi-select therefore has no accept key; it has a
`Done` row you move to.

### 3.1 Layout

Item on the left, its value on the right.

```
   1) DisplayPort 1                0x0F
   2) DisplayPort 2                0x10
   -- HDMI 1                       0x11   assigned to pc
   4) HDMI 2                       0x12
 > 5) Type a value...

  up/down move   enter choose   esc back
```

- The item column is **28 wide**, or the longest item + 1, capped at **44**.
- **Wrapping, never truncation.** A long detail wraps at the `", "` between
  items onto continuation lines aligned under the column. An unbreakable single
  item overruns rather than being cut.
- **Nothing a menu writes may exceed the terminal width.** A wrapped line's tail
  is not cleared on redraw and a line landing exactly on the fold counts as one
  row while occupying two, so the frame corrupts.
- Redrawing **erases each line to its end** rather than padding to the width;
  a measurement in bytes is not a measurement in columns.
- **One punctuation rule down the value column**: `", "` separates items, `": "`
  separates a label from its value, `"/"` joins things sharing one label. The
  wrapper breaks at `", "`.

### 3.2 Rows

- **Separator.** An empty item draws a blank line, skipped by the cursor.
- **Disabled row.** Drawn, annotated, skipped by the cursor, unpickable. Marked
  with `--` where the number would be. Never hidden: hiding changes the list's
  shape as you answer.
- **`(current)`** marks whatever is configured now, so a re-run can tell an
  unchanged default from a deliberate choice.

### 3.3 Keys

| key | does |
|---|---|
| up / down | move over selectable rows only |
| enter | what the highlighted row says |
| space | in a multi-select, toggles |
| esc | back, and change nothing |

| menu | esc does |
|---|---|
| a submenu you entered from somewhere | returns, changing nothing |
| the top menu | **moves the cursor to `Cancel`**; it does not activate it |
| a question that must be answered | nothing |

A setup cannot be discarded by one keypress. The hint line says what is
available and nothing more:

```normative
  up/down move   enter choose
  up/down move   enter choose   esc back
  up/down move   enter toggles the highlighted row
  up/down move   enter toggles the highlighted row   esc back
```

### 3.4 Multi-select

```
  > [x] usb:046d:0843    USB   Logitech Webcam C930e
    [ ] bt:0011223344ff  BT    AirPods Pro  (paired, not connected)
    [x] usb:1235:820a    USB   Clarett+ 2Pre

        Done                     2 selected

  up/down move   enter toggles the highlighted row   esc back
```

The layout rules of 3.1 apply here too. `Done` is a plain row aligned with the
item text, with a live count in the detail column. Enter on `Done` with nothing
checked refuses:

```normative
  Nothing is checked -- move to a row and press enter to check it.
```

### 3.5 The typed fallback

Both menus **must** fall back to typed input when the host cannot read
individual keys (a redirected stdin, a non-console host). It is how each
platform's suite drives `configure` end to end.

- Rows are numbered by position; disabled rows keep their position and show
  `--`.
- `q` is the fallback's `esc`, and only where esc is offered.
- Refusals re-ask:

```normative
  Pick a number from the list.
  Pick a number from the list, or q to go back.
  Pick at least one.
  Pick at least one, or q to go back.
```

**Running out of input is not an empty answer.** A required prompt at EOF
stops:

```normative
ran out of input. configure needs a terminal, or a complete script of answers.
```

---

## 4. The menu IS the flow

There is no separate first-run questionnaire. An empty install is the same menu
with `not set` in it and the cursor on the first thing that needs an answer;
finishing a section returns here with the cursor on the next.

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

```normative
Computers
Monitors
Triggers
Autostart?
Add to PATH?
Test the monitor inputs
Test the monitor input
Test the triggers
Test the trigger
Save configuration and run
Cancel (discard changes)
not set
untested
```

The check rows are singular when there is exactly one thing to check.

### 4.1 The header

```normative
--- configuration ---
--- review configuration ---
```

`--- configuration ---` until monitors **and** triggers are set, then
`--- review configuration ---`.

### 4.2 Where the cursor lands

The next thing that is not done: unanswered sections in order, then the checks
in order, then Save. **A failed check sends the cursor to the setting that
failed.** **Backing out of a check is neither a pass nor a failure**: its row
reads `not checked` and the cursor moves on.

### 4.3 Nothing is preset

Autostart and PATH have obvious answers, but the suggestion belongs on the
highlighted row inside their menu, not in the value column of a menu nobody has
opened.

### 4.4 Nothing is written until Save

An interrupted run leaves a working setup untouched. Save **refuses** while a
required section is `not set`, naming what is missing:

```normative
  Still needed:
```

The required sections are Computers, Monitors, Triggers, Autostart and PATH.
**The checks are not required**; they move hardware. Cancel discards everything:

```normative
cancelled; nothing was changed.
```

---

## 5. Computers

Asked **before** the monitors, so a computer is described once and every panel
offers the same names.

```normative
--- computers ---
These monitors are shared between this computer and some others.
Each one gets a name, and the name is how you switch to it:
    trigger-kvm to mac
```

```
  What should I call THIS computer? [mac-studio]
  How many OTHER computers are plugged into these monitors? [1]
  What is the other one called?

   1) mac                          this computer
   2) pc

   4) Add another computer
   5) Remove a computer
   6) Done
```

```normative
What should I call THIS computer?
How many OTHER computers are plugged into these monitors?
What is the other one called?
Name for computer
Add another computer
Remove a computer
this computer
  Pick a name to change it, or Done.
```

- First run asks for a **count** (capped at 16), then that many names.

```normative
  A number, please (16 at most).
```

- Then, always, the list: picking a name renames it; plus `Add another
  computer`, `Remove a computer` and `Done`. A re-run goes straight to the list.
- The default name for THIS computer is the host name, lower-cased and reduced
  to the character rule.

### 5.0 Enter keeps what is there

The rename prompt is pre-filled with the current name and **a blank answer keeps
it**, as every prompt in this walkthrough behaves. Removal is a row (5.3):
visible, typed-fallback-native, with a detail column to state the cost in.

### 5.1 One name per computer

The name is a config value, an argument you type (`trigger-kvm to mac`) and a
label in every prompt; there is no separate display name.

**Character rule: lowercase letters, digits and dashes.** Spaces and dots
become dashes; anything else is dropped. Suggest and ask, never silently mangle.

```normative
Lowercase letters, digits and dashes.
  A name is needed here.
  Names are what you type at a prompt, so:
```

A duplicate is refused:

```normative
There is already a computer called
```

### 5.2 What a change means

- A **rename** is carried into every panel's map; the monitors are not re-asked.
- A **removal** takes that computer out of every map.
- An **addition** leaves the maps alone; the Monitors row then shows which
  panels do not know about it yet.
- A rename or a removal that changes any map **invalidates a monitor-input
  pass** (10.8).

### 5.3 Removing a computer

```
--- remove a computer ---

 > 1) pc                          on lg and asus
   2) linux                       on lg

   4) Done
```

```normative
--- remove a computer ---
  Removing a computer also clears its input on every monitor it is on.
```

- `computer.this` is not offered: a config without it is one the switcher
  declines to act on.
- Each row's detail names the panels that computer is on.
- Removal is confirmed, defaulting to **no**:

```normative
  Its input on every monitor is cleared too. Nothing else changes.
```

---

## 6. Monitors

```
--- monitors ---

  > LG ULTRAGEAR+                lg: mac/pc
    PG42UQ                       not managed
    Dell U2723QE                 not attached

    Done
```

```normative
--- monitors ---
Which of these should follow the switch, and which input is each
computer on?
not managed
Manage this monitor?
Short name for it
```

- The list is **every attached panel plus every configured panel**. A configured
  panel that is not attached right now is shown as such, keeps every key on
  Save, and cannot be checked; it is not an answer and nothing is forgotten
  ([`config-format.md`](config-format.md), "Hand edits survive"). Only
  unmanaging forgets.
- A panel's own name comes from the EDID monitor-name descriptor (tag `0xFC`);
  a panel with none is named from its manufacturer and EDID id.
- The cursor lands on the first attached panel nobody has answered for, else
  on `Done`.
- Picking one asks: manage it? -> a short name -> the transport, where there is
  a choice (6.3) -> the method, where the vendor has one (6.2) -> **for each
  computer, which input it is on** (6.1). Machines-major, not inputs-major.
- **A panel's questions are one submenu.** Esc at any menu in it returns to the
  Monitors list with the panel exactly as it was. Backing out and declining are
  different things.
- **The short name is unique and follows the computer-name character rule**
  (5.1), with underscores also becoming dashes; suggested and asked. A second
  panel offered a name another already has is refused:

```normative
There is already a monitor called
```

- Answering **no** stops that panel following the switch and forgets which
  computer is on which of its inputs. When the panel has assignments to lose,
  that is confirmed and the loss named; a panel with nothing configured is not
  asked twice. Anything that discards configuration says what it discards and
  asks.

```normative
  Stop managing this monitor?
  Which computer is on which of its inputs is forgotten. Nothing else
```

- **Standard DDC/CI is the default for every panel.** An existing method is a
  settled answer and is not walked back to standard on a re-run.
- Looking at the list and changing nothing is not an edit and does not
  invalidate a pass.

### 6.1 Choosing an input

```normative
On the
which input is
(this computer -- the input you would pick to see this screen)
Type a value...
Not on this monitor
  Value (e.g. 0x11)
  Not a byte.
```

- The list is the channel's own values in the channel's own order. A typed
  value the channel does not list is appended, never inserted.
- An input already assigned to another computer is **disabled and annotated**:

```normative
assigned to
```

- A typed value that collides is refused. **Collision is by value, not
  spelling**: `17` and `0x11` are one socket, and a typed value is stored as
  canonical `0xNN`.

```normative
Two computers cannot share one input.
```

- Typing a value onto a manufacturer channel is warned about first:

```normative
  This is the manufacturer's service channel. Type only a value you have
  from documentation; an unknown value here has made monitors unusable.
```

- `Not on this monitor` is offered for every computer except this one. `Type a
  value...` is always offered.
- The cursor starts on the configured value's row; an unlisted value starts on
  `Type a value...`; a computer with no answer yet on `Not on this monitor`. It
  never starts on a row it cannot choose.
- A method changed in this sitting (6.2, 10.5) clears the panel's map: its
  values were for the other channel and are not offered as defaults.

### 6.2 Choosing how to talk to the monitor

Shown only when the panel's EDID vendor has a documented alternative, keyed by
vendor, never by model, from the same table the check escalates to. It comes
before the input questions, because the values on offer depend on the answer.

```
--- how to talk to this monitor ---
  Nearly every monitor takes the standard method, including most LG ones.
  A few LG models ignore it and need LG's own method instead.

  LG's own method talks to a service channel on the monitor. It is
  sent only the values written down for it: unknown values on that
  channel have made monitors unusable.

  If you are not sure, take the standard one. If it turns out not to
  work, the check further down will offer you this again.

 > 1) Standard                     what nearly every monitor takes   (current)
   2) LG's own method              for LG models that ignore the standard one
```

```normative
--- how to talk to this monitor ---
  Nearly every monitor takes the standard method, including most {vendor} ones.
  A few {vendor} models ignore it and need {vendor}'s own method instead.
  {vendor}'s own method talks to a service channel on the monitor. It is
  sent only the values written down for it: unknown values on that
  channel have made monitors unusable.
  If you are not sure, take the standard one. If it turns out not to
  work, the check further down will offer you this again.
Standard
what nearly every monitor takes
{vendor}'s own method
for {vendor} models that ignore the standard one
```

This is the moment a person commits to a service channel and the three warning
lines are the only warning they get. The values still come only from the
documented table or from what the user types; the transport gate is unchanged;
Standard remains the default and the cursor starts there on a fresh panel. A
dialect the chosen transport cannot carry is not offered.

### 6.3 Choosing how the bytes get there

Shown only where this panel enumerated through more than one of the platform's
transports. A platform with one transport, or a panel only one can see, asks
nothing and stores the transport it used. It comes before 6.2, because the
transport decides which dialects are available.

Enumerating is not probing: listing the platform's adapters and reading the
EDID each reports sends nothing to any monitor. The platform's original
transport is the default and the cursor starts there; where transports differ in
what they cover, the default is the one that covers more. The row names the
consequence in the person's terms: this monitor will not follow the switch
until someone logs in. No wording here is normative.

### 6.4 When two attached panels share one identity

A panel is identified by its EDID vendor:product pair, so two attached panels
reporting the same pair are one identity, and the switcher refuses to resolve
it. The walkthrough shows both (whether as two rows or one row naming the
count is the platform's) and **refuses to manage the identity**, taking no
answer for it, because configuration written against it could never switch
anything:

```normative
report the same id and cannot be told apart
A switch cannot aim at one of them
```

Unplugging one is the honest remedy today, and a platform may say so. It must
not guess: not the first, not the active one, not the lowest index. A tiebreak
that would tell such panels apart is designed and not built
([`../ideas/telling-two-identical-monitors-apart.md`](../ideas/telling-two-identical-monitors-apart.md)).
[`status.md`](status.md) 5 reports the same condition afterwards.

---

## 7. Triggers

```normative
--- triggers ---
Which devices move to this computer when you flip the switch?
USB rows are attached right now; Bluetooth rows are everything paired.
  Keyboards and mice often share a vendor id with something that never
  moves. The full vendor+product is matched, so pick the exact rows.
```

A multi-select over everything `discover` would list. **Bluetooth is offered on
PAIRED, not connected**: a trigger fires on arrival, so the device that is
disconnected right now is precisely the one that will produce one. Show the
state; never filter on it. Changing the selection invalidates a trigger pass.

A saved entry stays selected across a re-run whether or not its device is
attached, and is written back as it was unless the person changes it: a `where`
is not dropped because the device is away today.

### 7.1 A row is identified by WHAT THE DEVICE IS

**The row says what the device is; the id it is matched on stays visible beside
it.** A person recognises a device by its name and confirms it by its id.

- **Ask the platform for the best name it has, not the first.** Where a
  platform can report what the device says about itself as well as what its
  driver calls it, that is a second source.
- **Where a platform can say what a device presents itself as** (a mouse, a
  keyboard), show that too.
- **Neither the name nor the role may become a filter.** A hub, a device that
  looks internal, anything: show what is true and let the person decide. The
  only thing withheld is a node that is not a device at all (no vendor id).
- Where an id names more than one attached device, each device is its own row
  and the writer follows [`detector.md`](detector.md) 4.1 for what it writes.

None of this wording is normative. What is binding is the shape: name first, id
present, best-effort naming, nothing filtered.

---

## 8. Autostart

This section varies by platform and its wording is not normative. What is
normative is its shape:

- Three rows, in this order: from boot, from login, no. **From boot is the
  highlighted row**: a computer sitting at a login screen should still follow
  the switch.
- Where a tier cannot be provided with the same properties, its row is still
  **drawn**, says why in its detail, and is **disabled**, never hidden.
- An existing config still wins: an existing choice is a choice.
- **Answering no installs and starts the watcher now, for this session only.**
  Nothing brings it back after a restart or a new login; `restart` starts it
  again for that session.

```normative
--- should it start on its own? ---
From boot
From login
No -- I will start it myself
  Answering no still installs and starts it now; it just will not come
  back after a restart until you run:  trigger-kvm restart
```

| | Windows | macOS |
|---|---|---|
| boot | Scheduled Task, S4U principal, session 0, unelevated. Admin once, to register | LaunchDaemon in `/Library/LaunchDaemons` with `UserName` set, unelevated, no session. `sudo` once, to install |
| login | Scheduled Task, Interactive | LaunchAgent in `~/Library/LaunchAgents`, `RunAtLoad` + `KeepAlive` |
| no | task registered with no triggers, started now | agent plist kept out of `~/Library/LaunchAgents`, loaded now for this session |

**Elevation is needed once, to register, and nothing elevated runs on the
switch path.** A tier that required the switcher to run as root is not this
tier and must not be offered as it. **The tiers are mutually exclusive**:
installing one removes the other.

Where elevation cannot be obtained (a headless install, or a prompt that was
declined) the boot tier **falls back to login, says so, and the config records
login**:

```normative
falling back to starting at login
```

**Record the fallback only once it has taken effect.** A downgrade written
before the install that applies it has succeeded leaves the config disagreeing
with what is registered.

**A configured transport can be the reason a tier is unavailable**: where any
configured panel uses a transport that cannot switch it before login, the
`From boot` row is drawn disabled and its detail says which panel and why. It is
a property of the panel's transport, not of the account, and the two disabled
cases read differently. An existing boot tier given such a panel falls back to
login and says so.

Where the account cannot elevate at all, the `From boot` row is drawn disabled
before anything is asked for:

```normative
needs an administrator account
```

`status` says plainly what the installed tier covers.

---

## 9. PATH

Yes/no, with a suggestion on the highlighted row.

```normative
--- PATH ---
  Only that directory is added, and it holds only the launcher.
trigger-kvm works from anywhere
call it by its full path
```

Only a directory holding a single launcher goes on PATH, never the program
directory. The row is always drawn, `already on PATH` and disabled when there is
nothing to decide.

```normative
already on PATH
```

---

## 10. Checking the monitor inputs

What is under test is the claim that **input V of panel P is computer C**. A
panel that answers every command while its inputs are mapped to the wrong
computers fails this and is not broken.

### 10.1 Scope

Asked only when more than one panel is managed:

```normative
  Which monitor do you want to check?
All of them
```

Backing out here is not checked, never a pass. A configured panel that is not
attached is not offered.

```normative
not checked
```

### 10.2 Rounds

**Batched across panels, never across computers**, so several monitors are
confirmed in one glance rather than a sequence held in memory. Each round sends
every panel that claims a computer to that computer at once, holds ~8s, brings
them all back, and asks once.

```normative
  Sending {panels} to {computer} for {n}s, then back automatically.
  If {computer} is asleep or off you will see No Signal, which still proves the
  switch worked.
```

**Hard rule 4 applies: one panel always stays on this computer.** When every
panel being checked claims the target, that is two rounds. "What stays" is
measured against every managed, attached panel, not just this round's.

```normative
{panels} {stays} here, so you can read this.
  If this window is on {panels}, drag it to {other} first: if the switch back
  fails, the window goes dark with it and there is no way to answer.
  Enter when ready
```

The warning is said every round. **Every path that moves a panel goes through
this preamble**, including the transport-only check made when no other computer
is configured (the panel is sent to another of its inputs and back) and a
single-panel retry.

### 10.3 One question, then narrowing only on failure

```normative
  Did all of them show {computer}, then come back?
  Which ones did not?
```

A round with a single panel names it instead, and needs no narrowing question.

### 10.4 The four outcomes

Per failed panel, two questions, in the order it happened:

```normative
  Did the {monitor} change to {computer}, and back to {this}?
Yes, and it changed back to
Yes, but it did not change back to
everything works
  Did the {monitor} change at all?
Yes, but it was not
No, nothing happened
that input is not
this panel does not answer on this channel
```

| outcome | meaning | repair |
|---|---|---|
| 0 | correct | next |
| 1 | showed the wrong computer | re-ask **that computer's** input, retry |
| 2 | did not come back | re-ask **this computer's** input, or walk for it, retry |
| 3 | nothing happened | offer the **manufacturer dialect**, or say nothing known reaches this panel |

**One retry per fix, then take the answer. Do not loop.**

```normative
  So that input is not
  So {monitor} responds -- the channel is right. The input for this
  Do you know which input it is?
```

### 10.5 Switching method after a failure

Reached only from outcome 3. **Offered, never probed**, only for a vendor with
documented values, and only for a dialect the panel's transport can carry. The
values are shown before the question is asked. The offer is symmetric: a panel
on the standard method is offered the manufacturer one, and a panel already on
the manufacturer method is offered standard.

```normative
did not answer the standard channel. It is
panels put input switching on a manufacturer channel instead. These
sent -- nothing is guessed at on a manufacturer channel:
Yes, try the
No, leave this monitor out
and say which input each computer is on
everything else stays configured
```

Accepting it clears that panel's map. Going the other way:

```normative
is on {vendor}'s own method and did not answer it. The standard method
is the other thing to try.
Yes, try the standard method
```

With no documented values for that vendor, and already on standard:

```normative
did not answer the standard channel, and no manufacturer values
switching at all, or may use a channel nobody has documented.
Everything else is still configured; this monitor just will not follow
```

### 10.6 Blind value-walking, the last resort

**Standard DDC/CI only**, MCCS values one at a time, offered with its cost
stated, and **refused outright when it would take the last display**.

```normative
--- try the standard values one at a time ---
  Only offered on the standard channel. A manufacturer channel takes
  values from documentation or from you -- never from us guessing.
  COST: every wrong value moves that panel to another input. If none of
  them is right it will stay on the last one, and you will need the
  Go ahead?
Is the
showing THIS computer now?
```

```normative
  Not offered: the
  wrong guess would black out the screen you are reading. Use the
```

### 10.7 One monitor

Nothing can be held back, so if the switch back fails the person is looking at
a black screen. Being stranded without having been told how to get back is
avoidable, and the telling happens while there is still a screen to read it on.
It is said on every path that moves the only panel.

```normative
  READ THIS FIRST -- this is your only monitor.
  You will not be able to read anything while it is away.
  IF IT DOES NOT COME BACK there is nothing this tool can do for you --
  it cannot draw on a screen that is showing another computer. The way
  back is the monitor itself: press its input (or source) button and
  No software can take that button away from you.
  Ready?
```

The input is named in the monitor's own words (`choose HDMI 1, value 0x11`),
from the channel's own table. Declining reads as not checked:

```normative
  Skipped. Nothing was sent.
```

### 10.8 The result

```normative
all responded
trouble with
```

A failure names the panels in full. **A pass is bound to what was checked**:
the panels in scope, and each one's method, transport and map at the time.
Any edit to those, or a rename or removal that changes a map, invalidates it;
the row returns to `untested`. A pass covering one panel does not stand for the
others, and the trigger check (11) pulls for real only when every managed,
attached panel holds a current pass.

---

## 11. Checking the triggers

Checked **after** the monitor inputs: once the input values are confirmed, the
flip back can pull the monitors for real.

```normative
--- test the trigger ---
  Flip your switch AWAY from this computer, then back again. The way
  back is what a trigger is: the devices ARRIVING here.
```

- The watcher's one-shot mode prints current presence, waits for one arrival,
  reports it and exits, taking no lock and running nothing
  ([`detector.md`](detector.md) 3). It is given the entries as they will be
  saved, `where` included.
- The installed watcher is stood down for the check where that needs no
  elevation, and restored to the state it was in afterwards, on every way out
  including cancel and EOF. Where standing it down would need a password or a
  prompt, it is left running and the person is told before they flip:

```normative
  The running watcher is paused for this check.
  The running watcher will also fire, using the saved configuration.
```

- Until the inputs hold a current pass it reports the arrival and moves
  nothing:

```normative
  The arrival will be reported but the monitors will NOT be moved:
  check them first (the row above) and this becomes the real thing.
```

- Once they do, the arrival pulls for real, against a throwaway config holding
  the unsaved answers:

```normative
  When they do, the monitors will be pulled here for real, using the
  values you just checked. That is the whole thing working end to end.
  Pulling the monitors here...
  Did the monitors come back to this computer?
```

- A "no" there is a monitors fault with the trigger passing:

```normative
  The trigger fired, so the devices are right. Something about the
  monitors is not -- check them again from the row above.
  Nothing arrived, so these may be the wrong devices -- or they may not
  be on the switch at all. Pick Triggers again to change them.
```

```normative
arrival seen
fired, monitors followed
no arrival seen
fired, but the monitors did not follow
```

---

## 12. Saving

Write the config, apply the PATH answer, apply the autostart answer, then say
what is left to say. Short: it runs, here is how to see that, here are four
commands. Nothing in the closing words claims a state that was not reached; a
tier that failed to load says so instead.

```normative
  Flip your switch to this computer -- the monitors should follow.
status      is it running?
pull        bring the displays here now
logs        what has it been doing
configure   change any of this
```
