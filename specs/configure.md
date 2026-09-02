# `trigger-kvm configure` — normative

The walkthrough. It is how a machine goes from nothing to a working setup, and
how every setting is changed afterwards.

`configure --fresh` runs the same walkthrough pre-filling nothing.

Read [`README.md`](README.md) first for how normative wording is marked and
enforced. The hard safety rules this flow obeys are in
[`../AGENTS.md`](../AGENTS.md) and are not restated here.

---

## 1. What it is for

To produce a [config](config-format.md) that describes **which computer is on
which input of which monitor**, and to prove that description is true by moving
the monitors while someone watches.

Everything it asks is in service of that. If a question does not change what
gets written or what gets checked, it should not be asked.

## 2. Voice

Short sentences. Say the thing, then say why if the why is not obvious.

- **Plain words over jargon.** "monitor", not "panel" or "display device". Say
  `EDID` or `DDC/CI` only where the reader needs the term to look something up.
- **"computer", never "machine"**, everywhere the user can see it. The config key
  is `computer.this`; the walkthrough asks what to call THIS computer; the term
  must not change between them.
- **Name the consequence, not the mechanism.** "if the switch back fails, the
  window goes dark with it and there is no way to answer" — not "the DDC write
  may not be acknowledged".
- **No exclamation marks, no apology, no reassurance.** A person about to lose a
  monitor wants the facts.
- Second person for what the reader does; first person only where the tool is
  the actor ("I will send each standard input value in turn").

## 3. UI grammar

Every list question is one of two menus, and in both:

> **Enter does what the highlighted row says.**

That single rule is the whole design. With "space toggles, enter accepts" the
first thing people did was accept an empty list, because enter is what you
press. So a multi-select has **no accept key** — it has a `Done` row you move to.

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
  Fixed at 28, a long row ran its detail straight on with no gap, which reads as
  one sentence rather than a choice and its consequence.
- **Wrapping, never truncation.** A long detail wraps at the `", "` between items
  onto continuation lines aligned under the column. Truncating hid the very
  values the review screen exists to let someone check. An unbreakable single
  item overruns rather than being cut.
- **Nothing a menu writes may exceed that width**, and this is load-bearing
  rather than cosmetic. A longer line wraps; a wrapped line's tail is not
  cleared when the frame is redrawn, so the previous frame shows through; and a
  line landing exactly on the terminal's fold occupies two rows while a naive
  count says one, so the frame stacks downward and repeats itself. Both were
  reported from a real 80-column terminal.
- Redrawing **erases each line to its end** rather than padding it to the width.
  Padding has to measure the line, and a measurement in bytes is not a
  measurement in columns — a name containing a typographic apostrophe pads short
  and leaves the previous frame showing.
- **One punctuation rule down the value column**, because it is read as a column:
  `", "` separates items, `": "` separates a label from its value, `"/"` joins
  things sharing one label. Not cosmetic — the wrapper breaks at `", "`, so a row
  using anything else cannot wrap.

### 3.2 Rows

- **Separator.** An empty item draws a blank line, is skipped by the cursor and
  cannot be chosen. Used to group a long menu.
- **Disabled row.** Drawn, annotated, skipped by the cursor, unpickable — an
  input already assigned to another computer. Hiding it would make the list
  change shape as you answer; renaming it would lose the only label the monitor's
  own menu agrees with. Marked with `--` where the number would be.
- **`(current)`** marks whatever is configured now. Starting the cursor there is
  not enough: the cursor also means "where you are", so a re-run gave no way to
  tell an unchanged default from a deliberate choice.

### 3.3 Keys

| key | does |
|---|---|
| up / down | move over selectable rows only |
| enter | what the highlighted row says |
| space | in a multi-select, toggles — for anyone who reaches for it |
| esc | back, and change nothing |

**Esc always means "take me to the way out"** — but what the way out *is*
depends on the menu, and it is never "discard everything on one keypress".

| menu | esc does |
|---|---|
| a submenu you entered from somewhere | returns, changing nothing |
| the top menu | **moves the cursor to `Cancel`** — it does not activate it |
| a question that must be answered | nothing |

On the top menu it moves rather than acts, so a setup still cannot be discarded
by a stray keypress: you have to press enter on a row that says
`Cancel (discard changes)`. That keeps the property while making esc do the
useful thing instead of nothing.

The hint line says what is available and nothing more:

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

**The layout rules in §3.1 apply here too** — the same item column, the same
wrapping of the detail at `", "`, the same "never truncate". A multi-select is
where they matter most, because device names are long and arrive from the
system rather than being chosen: a row that overflows wraps, and a wrapped row's
tail is not cleared by the next frame, so the previous frame shows through at
the right edge and the redraw corrupts.

- `Done` is a **plain row aligned with the item text**, with a live count in the
  detail column where every other menu puts a value. It was a bracketed button
  for a while; every other menu ends with a bare `Done`, so the brackets read as
  inconsistency.
- Enter on `Done` with nothing checked **refuses** and says so:

```normative
  Nothing is checked -- move to a row and press enter to check it.
```

### 3.5 The typed fallback

Both menus **must** fall back to typed input when the host cannot read
individual keys — a redirected stdin, a non-console host, a session that does not
forward keys.

This is not a nicety. It is what makes the whole flow testable end to end, and
it is how each platform's suite drives `configure`.

- Rows are numbered by position; disabled rows keep their position but are shown
  unnumbered as `--`.
- `q` is the fallback's `esc`, and only where esc is offered.
- Refusals re-ask:

```normative
  Pick a number from the list.
  Pick a number from the list, or q to go back.
  Pick at least one.
  Pick at least one, or q to go back.
```

**Running out of input is not an empty answer.** A required prompt that re-asks
on a blank answer will re-ask forever once stdin is at EOF. It must stop:

```normative
ran out of input. configure needs a terminal, or a complete script of answers.
```

---

## 4. The menu IS the flow

There is no separate first-run questionnaire. An empty install is the same menu
with `not set` in it and the cursor already on the first thing that needs an
answer. Finishing a section returns here with the cursor on the next unanswered
one.

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

The check rows are singular when there is exactly one thing to check:
`Test the monitor input` for a single claim, `Test the trigger` for a single
device.

### 4.1 The header

```normative
--- configuration ---
--- review configuration ---
```

`--- configuration ---` until monitors **and** triggers are set, then
`--- review configuration ---`.

### 4.2 Where the cursor lands

Where the cursor lands is the recommendation, and it is just "the next thing
that is not done":

1. unanswered sections, in order
2. then the checks, in order
3. then Save

**A failed check sends the cursor to the setting that failed**, not onward: a
failed monitor check lands on Monitors, a failed trigger check on Triggers.

**Backing out of a check is neither a pass nor a failure.** Its row reads
`not checked` and the cursor moves on to the next unfinished thing, as if the
check had not been opened. Landing on Monitors would say "you got the monitors
wrong" to someone who only declined to move them.

### 4.3 Nothing is preset

Autostart and PATH have obvious answers, but the suggestion belongs on the
highlighted row **inside** their menu, not in the value column of a menu nobody
has opened. One of those answers may ask for administrator permission; the other
edits a PATH. Showing an answer nobody gave is the tool answering on someone's
behalf.

### 4.4 Nothing is written until Save

An interrupted run must leave a working setup untouched — not a half-written
config plus an autostart entry pointing at it.

Save **refuses** while a required section is `not set`, naming what is missing.
Writing half a setup produces a config the switcher then declines to act on,
which is a worse way to find out.

```normative
  Still needed:
```

The required sections are Computers, Monitors, Triggers, Autostart and PATH.
**The checks are not required** — they move hardware, and someone may reasonably
decline.

Cancel discards everything:

```normative
cancelled; nothing was changed.
```

---

## 5. Computers

Asked **before** the monitors, so a computer is described once rather than once
per screen, and so every panel then offers the same names.

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

- First run asks for a **count**, then that many names. "One per line, blank line
  when there are no more" made people guess both how to finish and whether a
  blank meant cancel. The count is capped at 16.

```normative
  A number, please (16 at most).
```

- Then, **always**, the list: picking a name **renames** it; plus
  `Add another computer`, `Remove a computer` and `Done`. A re-run goes straight
  to this list.
- The default name for THIS computer comes from the host name, lower-cased and
  reduced to the character rule. It is never typed in anger — `pull` is the verb.

### 5.0 Enter keeps what is there

The rename prompt is pre-filled with the current name, and **a blank answer keeps
it**, exactly as every other prompt in this walkthrough behaves.

It used to **remove the computer**, which made the most innocuous keypress
available the destructive one. That is the same failure as accepting an empty
multi-select (§3) — enter is what people press — and it showed up in the code as
a workaround: the prompt had to withhold its own default, because supplying one
would have made removal unreachable. A question that cannot follow the tool's own
convention is the wrong question, not a question needing an exception.

**Removal is a row instead**, for three reasons that all point the same way: it
is visible in the list rather than being a gesture you have to know; it works in
the typed fallback (§3.5), which a keypress does not, and which is what each
platform's suite drives; and a row has a detail column to state the cost in.

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

- **`computer.this` is not offered.** This computer is not optional: its name is
  what `pull` resolves, and a config without it is one the switcher declines to
  act on.
- Each row's detail names the panels that computer is on, so the cost is visible
  **before** the row is chosen, not only after.
- Removal is confirmed, and the confirmation is where the consequence is stated
  in full. It defaults to **no**:

```normative
  Its input on every monitor is cleared too. Nothing else changes.
```

- Nothing is written until Save (§4.4), so a removal is still recoverable by
  Cancel. That is a backstop, not the reason the confirmation can be skipped.

### 5.1 One name per computer

Not a slug plus a display name. The name is a config value, an argument you type
(`trigger-kvm to mac`), and a label in every prompt; a second field would be a
second thing to keep in step for the sake of capital letters.

**Character rule: lowercase letters, digits and dashes.** Spaces and dots become
dashes; anything else is dropped.

It must **suggest and ask**, never silently mangle — the first version stripped
what it did not like, so "My Mac" quietly became "mymac".

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

- A **rename is carried into every panel's map.** Do not re-ask the monitors:
  that was tried and it threw away answers nobody asked to change.
- A **removal** takes that computer out of every map.
- An **addition** leaves the maps alone; the Monitors row then shows which panels
  do not know about it yet.
- A rename or a removal **invalidates a monitor-input pass**, because the values
  that passed are no longer the values configured.

---

## 6. Monitors

```
--- monitors ---

  > LG ULTRAGEAR+                lg: mac/pc
    PG42UQ                       not managed

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

- The panel's own name comes from the **EDID monitor-name descriptor (tag
  `0xFC`)**. Asking the hardware beats a table, which only ever knows the
  monitors its author owned. A panel with no such descriptor is named from its
  manufacturer and EDID id.
- The cursor lands on the first panel nobody has answered for, else on `Done`.
- Picking one asks: manage it? → a short name → **for each computer, which input
  it is on**. **Machines-major, not inputs-major**: a panel has eight possible
  inputs and two real ones.
- **A panel's questions are one submenu.** Esc at any menu in it — how to talk
  to it, any input — abandons that panel and returns to the Monitors list with
  the panel exactly as it was. Half a map is not an answer, so nothing part-way
  through is kept. This is deliberately **not** the same as answering
  `Manage this monitor?` with no: backing out and declining are different
  things, and collapsing them would let a stray esc unmanage a working monitor.
- **The short name is unique, and follows the computer-name character rule**
  (§5.1): lowercase letters, digits and dashes; spaces, dots and underscores
  become dashes; anything else is dropped — suggested and asked, never silently
  mangled. Two panels with one name would be written as one panel and read back
  as a merge of both, and the switcher would refuse without saying why. A
  second panel offered a name another already has is refused and asked again:

```normative
There is already a monitor called
```
- Answering **no** stops that panel following the switch and **forgets which
  computer is on which of its inputs**. That is more than the question implies —
  "manage" sounds like a flag, and the answer is destructive — so when the panel
  has assignments to lose, it is confirmed and the loss is named. A panel with
  nothing configured has nothing to lose and is not asked twice.

```normative
  Stop managing this monitor?
  Which computer is on which of its inputs is forgotten. Nothing else
```

  This is the same rule as removing a computer (§5.3), and deliberately so:
  **anything that discards configuration says what it discards and asks.** That
  is the symmetry worth having between the two menus — not a shared keystroke.
  A monitor is bolted to the desk and cannot be deleted; only its assignments can,
  which is why this stays a question about managing rather than becoming a
  `Remove` row.
- **Standard DDC/CI is the default for every panel, whatever the make.** An
  existing method is a settled answer — it was proven by someone watching a
  screen — and must not be walked back to standard on a re-run.
- Where the panel's manufacturer has a **documented alternative**, that choice is
  offered **up front**, immediately after the short name and before any input is
  asked for. See §6.2.
- Looking at the list and changing nothing is **not** an edit, and must not
  invalidate a pass.

### 6.3 Choosing how the bytes get there

**Shown only where a choice exists** — where this panel enumerated through more
than one of the platform's transports. A platform with one transport, or a panel
only one transport can see, asks nothing and stores the transport it used.

**It comes before §6.2**, because the transport decides which dialects are even
available: a transport that cannot address an I2C source byte cannot carry a
manufacturer sidechannel, so offering that dialect first and refusing it second
would be asking a question whose answer was already fixed.

**Enumerating is not probing.** `AGENTS.md` 1b forbids probing a *monitor* —
sending it values to see what it does. Listing the platform's adapters and
reading the EDID each one reports sends nothing to any monitor, so building the
offer from what enumerated is not a probe. The distinction is worth keeping
sharp: what is forbidden is discovering a monitor's behaviour by experiment, not
discovering which of this computer's own APIs can see it.

**The platform's original transport is the default**, and the cursor starts
there. Where transports differ in what they can cover, the default is the one
that covers more — a person who does not have an opinion should land on the one
with fewer consequences.

**Name the consequence where the choice is made**, per §2. Where a transport
cannot cover a tier the other one can — a transport that needs a desktop cannot
switch a panel before anyone has logged in — that is what the row says, in terms
of what the person will experience: this monitor will not follow the switch
until someone logs in. Not the mechanism, and not a reassurance.

**No wording here is normative.** A platform with a single transport never shows
this question, and pinning a string would make it owe text for a menu it does not
have. What is binding is the shape above and the `transport` key in
[`config-format.md`](config-format.md).

### 6.2 Choosing how to talk to the monitor

Shown **only** when the panel's EDID vendor has a documented alternative. This is
keyed by vendor, never by model, and comes from the same table the check
escalates to — there is one list of manufacturer methods, not two.

It comes **before** the input questions, because the values on offer depend on
which method is chosen.

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

**The consequence is named where the choice is made.** This is the moment a
person commits to a service channel, and §2's rule is to name the consequence,
not the mechanism. The hard rules that make the channel safe live in
[`../AGENTS.md`](../AGENTS.md), which a user never opens; three lines here are
the only warning they get. No exclamation mark, no reassurance: what the channel
is, what is sent to it, what has happened on it.

**Why up front rather than only on failure.** Someone who already knows their
model needs the alternative should not have to run a check that moves a panel
and sends packets purely in order to fail. And someone who knows they need it,
sees the standard method fail, and has not been told the alternative exists may
reasonably conclude the tool does not know about it and give up before the check
offers it.

**What this does not change**, and must not:

- The values still come **only** from the documented table or from what the user
  types in that moment. Nothing is probed, swept, or guessed. See
  [`../AGENTS.md`](../AGENTS.md) hard rule 1.
- The transport gate is unchanged: a manufacturer channel is refused for a panel
  whose EDID vendor does not match, in code, at the transport.
- **Standard remains the default** and the cursor starts there on a fresh panel.

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

- The list is the channel's own values **in the channel's own order**. A value
  someone typed that the channel does not list is **appended** so it can be
  shown, never inserted.
- An input already assigned to another computer is **disabled and annotated**,
  because two computers cannot share a socket:

```normative
assigned to
```

- A typed value that collides is refused with the same reasoning, because
  marking it in the list is not enough — a typed value can still reach it.
  **Collision is by value, not by spelling**: `17` and `0x11` are one socket.
  A typed value is stored in the canonical `0xNN` form, so the same input never
  appears twice in a map or a list under two spellings:

```normative
Two computers cannot share one input.
```

- **Typing a value onto a manufacturer channel is warned about first.** The
  channel is what §6.2 named; a typed byte is the one thing that reaches it
  from outside the documented table, and hard rule 1 permits it only because
  the person typing it is the one who has to know where it came from:

```normative
  This is the manufacturer's service channel. Type only a value you have
  from documentation; an unknown value here has made monitors unusable.
```

- `Not on this monitor` is offered for every computer **except this one**.
  `Type a value...` is always offered.
- The cursor starts on the configured value's row, so a re-run is a review rather
  than a re-entry. An unlisted value starts on `Type a value...`; a computer with
  no answer yet starts on `Not on this monitor`. It never starts on a row it
  cannot choose.

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
PAIRED, not connected** — a trigger fires on arrival, so the device that is
disconnected right now is precisely the one that will produce one. Show the
state; never filter on it.

Changing the selection invalidates a trigger pass.

---

## 8. Autostart

**This section varies by platform and its wording is not normative.** What is
normative is its shape:

- Three rows, in this order: from boot, from login, no.
- **From boot is offered first.** A computer sitting at a login screen should
  still follow the switch.
- Where a tier cannot be provided with the same properties, its row is still
  **drawn**, says why in its detail, and is **disabled** — never hidden. The menu
  keeps the shape someone coming from the other platform expects, and the
  question it raises is answered where it is asked.
- An existing config still wins: an existing choice is a choice.
- Answering no still installs and starts it now; it just will not come back after
  a restart.

```normative
--- should it start on its own? ---
From boot
From login
No -- I will start it myself
  Answering no still installs and starts it now; it just will not come
  back after a restart until you run:  trigger-kvm restart
```

Platform notes, and the reason the row differs:

| | Windows | macOS |
|---|---|---|
| boot | Scheduled Task, S4U principal — runs **as the user, unelevated**, in session 0. Admin once, to register. | LaunchDaemon in `/Library/LaunchDaemons` with `UserName` set — runs **as the user, unelevated**, with no session. sudo once, to install. |
| login | Scheduled Task, Interactive | LaunchAgent in `~/Library/LaunchAgents`, `RunAtLoad` + `KeepAlive` |
| no | task registered with no triggers | agent installed but not loaded; `restart` loads it |

Both platforms hold the same property, and it is the point of the tier:
**elevation is needed once, to register, and nothing elevated runs on the switch
path.** A tier that required the switcher itself to run as root would not be
this tier and must not be offered as it.

The tiers are **mutually exclusive**. Installing one removes the other, because
two live watchers would both fire on the same arrival and the debounce is
per-process, so it cannot dedupe across them.

Where elevation cannot be obtained — a headless or non-interactive install, or
a prompt that was declined — the boot tier **falls back to login, says so, and
the config records login**, not what was asked for. Nothing elevates without
someone choosing it, and silently keeping `boot` is how someone finds out months
later that switching does nothing until they log in.

```normative
falling back to starting at login
```

**A configured transport can be the reason a tier is unavailable**, and it takes
the same shape: where any configured panel uses a transport that cannot switch it
before login, the `From boot` row is drawn **disabled**, and its detail says
which panel and why. It is a property of the panel's transport, not of the
account, so the two disabled cases read differently and must not be merged.

Where an existing config already chose that tier and a panel is then given such a
transport, the tier **falls back to login and says so** — the same shape as a
declined elevation. **Record the fallback only once it has taken effect.** A
downgrade written before the install that applies it has succeeded leaves the
config disagreeing with what is registered, and the next install acts on the
config.

Where the account **cannot** elevate at all — it is not an administrator — the
`From boot` row is drawn disabled, and its detail says so, before anything is
asked for. Offering it would otherwise send the most common kind of account
into a prompt for a different account's credentials, and whatever that
installs belongs to that other account.

```normative
needs an administrator account
```

`status` must **say plainly** what the installed tier covers, and where a tier
is unavailable rather than implying the platforms match.

---

## 9. PATH

Yes/no, with a suggestion on the highlighted row.

```normative
--- PATH ---
  Only that directory is added, and it holds only the launcher.
trigger-kvm works from anywhere
call it by its full path
```

Only a directory holding a **single launcher** goes on PATH — never the program
directory, which would publish every file in it as a command.

The row is **always drawn**, showing `already on PATH` and disabled when there is
nothing to decide. Omitting it moved every row below it and left the cursor
apparently skipping a step.

```normative
already on PATH
```

---

## 10. Checking the monitor inputs

What is under test is the claim that **input V of panel P is computer C**. A
panel that answers every command perfectly while its inputs are mapped to the
wrong computers fails this and is not broken. Hence "test the monitor
**inputs**".

### 10.1 Scope

Asked only when more than one panel is managed:

```normative
  Which monitor do you want to check?
All of them
```

Backing out here is **not checked**, never a pass.

```normative
not checked
```

### 10.2 Rounds

**Batched across panels, never across computers.** Monitors sit side by side, so
several are confirmed in one glance; a *sequence* over half a minute has to be
held in memory and reported afterwards, and memory is the weak link.

Each round sends every panel that claims a computer to that computer at once,
holds ~8s, brings them **all back automatically**, and asks once.

```normative
  Sending {panels} to {computer} for {n}s, then back automatically.
  If {computer} is asleep or off you will see No Signal, which still proves the
  switch worked.
```

**Hard rule 4 applies: one panel always stays on this computer**, so the question
arrives on a screen that can be read. When every panel being checked claims the
target, that is **two rounds** — the second covers the one held back.

"What stays" is measured against **every managed panel**, not just this round's:
a panel nobody asked about is still somewhere to put a window.

```normative
{panels} {stays} here, so you can read this.
  If this window is on {panels}, drag it to {other} first: if the switch back
  fails, the window goes dark with it and there is no way to answer.
  Enter when ready
```

The warning is **said every round**, not asked once. An earlier version asked
which monitor the window was on so it could schedule that panel last; that is a
question about the tool's convenience, and people could not answer it
confidently.

### 10.3 One question, then narrowing only on failure

```normative
  Did all of them show {computer}, then come back?
  Which ones did not?
```

A round with a single panel names it instead, and needs no narrowing question.

### 10.4 The four outcomes

Per failed panel, **two questions, in the order it happened**. One question with
four answers made the reader hold every failure in mind at once to find their
own; this asks the thing they just watched, and only the "no" leads anywhere
else.

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

Reached only from outcome 3 — the panel did nothing at all, so the channel is
wrong. **Offered, never probed**, and only for a vendor that has documented
values. The values are shown before the question is asked.

The offer is **symmetric**: a panel on the standard method is offered the
manufacturer one, and a panel already on the manufacturer method is offered
standard. Since §6.2 lets someone choose the manufacturer method up front, a
panel can arrive here already on it — and telling that person "no manufacturer
values are known" would be both false and a dead end.

```normative
did not answer the standard channel. It is
panels put input switching on a manufacturer channel instead. These
sent -- nothing is guessed at on a manufacturer channel:
Yes, try the
No, leave this monitor out
and say which input each computer is on
everything else stays configured
```

Accepting it **clears that panel's map**: every value in it was for a channel
that does not work, so carrying the numbers across would be meaningless.

Going the other way, back to standard:

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

### 10.6 Blind value-walking — the last resort

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

Refused when it is the only monitor, because a wrong guess would black out the
screen the question is printed on:

```normative
  Not offered: the
  wrong guess would black out the screen you are reading. Use the
```

### 10.7 One monitor

**A special case that must be handled explicitly.** Nothing can be held back, so
if the switch back fails the person is looking at a black screen. That is
unavoidable; being stranded *without having been told how to get back* is not,
and the telling has to happen while there is still a screen to read it on.

```normative
  READ THIS FIRST -- this is your only monitor.
  You will not be able to read anything while it is away.
  IF IT DOES NOT COME BACK there is nothing this tool can do for you --
  it cannot draw on a screen that is showing another computer. The way
  back is the monitor itself: press its input (or source) button and
  No software can take that button away from you.
  Ready?
```

The input is named **in the monitor's own words** — the OSD has never heard of
`pc`. So: `choose HDMI 1, value 0x11`, from the channel's own table, never from
the computer map.

Declining reads as **not checked**, never as a pass:

```normative
  Skipped. Nothing was sent.
```

### 10.8 The result

```normative
all responded
trouble with
```

A failure names the panels **in full**. Panel names contain spaces, and a
space-separated list reported two monitors that do not exist.

---

## 11. Checking the triggers

Checked **after** the monitor inputs, and that ordering is the point: once the
input values are confirmed, the flip *back* can pull the monitors for real, so it
stops being "an event was observed" and becomes the whole thing working.

```normative
--- test the trigger ---
  Flip your switch AWAY from this computer, then back again. The way
  back is what a trigger is: the devices ARRIVING here.
```

- The watcher gets a **one-shot mode** that prints current presence, waits for one
  **arrival**, reports it and exits. It takes **no lock and runs nothing**, so a
  real watcher may run alongside it.
- **The installed watcher is stood down for the check** where that needs no
  elevation, and restored afterwards. On a re-run it would otherwise see the
  same flip and pull against the SAVED config, after the one-shot's pull — so a
  correct new answer would read as the monitors failing. Where standing it down
  would need a password or a prompt, it is left running and the person is told
  before they flip:

```normative
  The running watcher is paused for this check.
  The running watcher will also fire, using the saved configuration.
```
- Until the inputs are checked it reports the arrival and **moves nothing**,
  saying so:

```normative
  The arrival will be reported but the monitors will NOT be moved:
  check them first (the row above) and this becomes the real thing.
```

- Once they pass, the arrival pulls for real — against a **throwaway config**,
  because the answers are not written yet and the saved config would move the
  panels to whatever was configured before:

```normative
  When they do, the monitors will be pulled here for real, using the
  values you just checked. That is the whole thing working end to end.
  Pulling the monitors here...
  Did the monitors come back to this computer?
```

- A "no" there is a **monitors** fault with the trigger passing, which is a
  different diagnosis from "nothing arrived":

```normative
  The trigger fired, so the devices are right. Something about the
  monitors is not -- check them again from the row above.
  Nothing arrived, so these may be the wrong devices -- or they may not
  be on the switch at all. Pick Triggers again to change them.
```

Row states: `arrival seen`, `fired, monitors followed`, `no arrival seen`,
`fired, but the monitors did not follow`.

```normative
arrival seen
fired, monitors followed
no arrival seen
fired, but the monitors did not follow
```

---

## 12. Saving

Write the config, apply the PATH answer, then restart the watcher so the new
trigger settings take effect. Then say what is left to say — short. It runs, here
is how to see that, here are four commands.

```normative
  Flip your switch to this computer -- the monitors should follow.
status      is it running?
pull        bring the displays here now
logs        what has it been doing
configure   change any of this
```

Everything else — how it starts, sessions, the transport — is in the docs for the
day someone needs it, and is noise on the day they do not.
