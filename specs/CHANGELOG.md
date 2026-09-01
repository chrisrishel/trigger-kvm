# specs — changelog

**Behaviour changes implementations must act on.** Newest first.

This is not a git duplicate. Git records every edit to `specs/`, including
rewording and typo fixes; this records only the changes that give an
implementation something to do. If an entry does not create work for a platform,
it does not belong here.

## How it is used

The **revision is the number of the newest entry below.** Each implementation
records the revision it is known to implement in its own `SPEC-REVISION` file,
and its own test suite fails while that is behind. So a platform learns it is out
of date from its own test run, with no one having to tell it — which is what
makes this scale to a third implementation for free.

**When you land a spec change:**

1. Add an entry here with the next number.
2. Implement it on the platform you are working on and bump that platform's
   `SPEC-REVISION`.
3. Leave every other platform's `SPEC-REVISION` alone. Their suites will now
   fail, which is the point, and they will read the entries between their number
   and this one to find out what they owe.

You do **not** append to every other platform's `HANDOFF.md` for a spec change.
That is fan-out: N−1 edits per change, worse with every platform added, and
silent if one is forgotten. A `HANDOFF.md` is for what the machinery *cannot*
tell a platform — chiefly a defect someone found in its code by reading it.

Fan out when the message is N different claims. Publish once when it is one fact.

## What an entry has to carry

**This file is the ONLY context channel for a spec change**, since none is fanned
out to the platforms. That is a fair trade only while an entry actually carries
the context a handoff would have. A thin entry — "§5 changed" — breaks the deal,
and the next person's instinct that they should have been written to directly
becomes correct.

So every entry carries, and the entries below are the worked examples:

- **What changed, in one bold line** a reader can match against a symptom.
- **`Sections:`** — the exact spec sections, linked. This is "where it is
  relevant"; the conformance failure gives strings, not places.
- **`Act on:`** — what an implementation must DO, as opposed to what the spec now
  says. Name a platform where they differ: revision 4 is macOS-only, revision 3
  named the file and function Windows had to change.
- **Why the old behaviour was wrong.** The reasoning does not survive in the spec
  — the spec describes what is true now, not what it replaced — so if it is not
  here it is nowhere, and someone re-proposes the old design in a year.

What does NOT go here: how a platform should implement it. That is the thing the
other platform is better placed to decide, and the thing you cannot check, since
you can neither run its tests nor see its hardware.

## Why this exists alongside the conformance check

The conformance check already tells every platform when the spec adds a string
it does not have. It is blind to two things, and this closes them:

- **Behavioural changes with no new wording** — "the cursor lands on the first
  check rather than Save" has nothing to grep for.
- **Removed or renamed strings** — the check tests presence only, so a platform
  keeps old wording forever and stays green.

---

## Revision 6 — 2026-09-01

**Name the consequence at the service channel; a panel is one submenu; the
walkthrough refuses what the switcher would refuse later.**

Sections: [`configure.md`](configure.md) §4.2, §6, §6.1, §6.2, §8, §11.

**Act on (both platforms):**

1. **§6.2 — three lines in the method chooser** say what the manufacturer method
   is (a service channel), what is sent to it (only the recorded values) and
   what has happened on it (monitors made unusable). **§6.1 — two lines before
   the typed-value prompt** when the method is a manufacturer channel. Both are
   normative wording.

2. **§6 — a panel's questions are one submenu.** Esc at any menu in it returns
   to the Monitors list with the panel unchanged. Windows already does this;
   macOS advanced to the input questions instead.

3. **§6 — the short name is unique and follows §5.1's character rule**,
   suggested and asked. A duplicate is refused: `There is already a monitor
   called`. Windows strips underscores where the rule turns them into dashes.

4. **§6.1 — typed-value collision is by value**, and a typed value is stored as
   canonical `0xNN`. `17` and `0x11` were accepted as two sockets on both
   platforms.

5. **§8 — a declined prompt is "cannot be obtained"**: fall back to login, say
   `falling back to starting at login`, record login. macOS did; Windows exited
   with the config still saying boot and the watcher not restarted. And where
   the account is not an administrator, the `From boot` row is drawn disabled
   with `needs an administrator account` — on Windows this is the row that sent
   a standard account into a different account's UAC prompt.

6. **§11 — the trigger check stands the installed watcher down** where that
   needs no elevation and restores it after; otherwise it says `The running
   watcher will also fire, using the saved configuration.` before the flip.

7. **§4.2 — backing out of a check is not a failure**; the cursor does not go
   to Monitors.

**Why.** The review before publication found the bricking hazard stated only in
`AGENTS.md`, a file a user never opens, while the two moments a person actually
commits to the service channel said nothing. §2 already required naming the
consequence; this applies it. The rest are places where the two implementations
had quietly diverged (esc in the panel flow, the label rule, the declined
prompt) or where both accepted an answer the switcher would refuse later
(duplicate labels, `17` vs `0x11`) — the walkthrough exists to refuse those
while the person can still say what they meant.

## Revision 5 — 2026-08-31

**Enter must never destroy. Removing a computer becomes a row, and unmanaging a
monitor states what it forgets.**

Sections: [`configure.md`](configure.md) §5, §5.0, §5.3, §6.

**Act on (both platforms):**

1. **§5.0 — the rename prompt keeps the name on a blank answer**, pre-filled with
   the current name like every other prompt. It used to REMOVE the computer.

2. **§5.3 — a `Remove a computer` row**, between `Add another computer` and
   `Done`, opening a list that excludes `computer.this`, names the panels each
   computer is on in the detail column, and confirms with a default of no.

3. **§6 — answering no to `Manage this monitor?` confirms** when the panel has
   assignments, naming what is forgotten. A panel with none is not asked twice.

**Why.** Blank-means-remove made the most innocuous keypress available the
destructive one — the same failure as accepting an empty multi-select, which §3
already exists to prevent, for the same reason: enter is what people press.

It was visible in the code as a workaround before it was visible in use. The
prompt had to withhold its own default, because supplying one would have made
removal unreachable; the comment saying so was still there. A question that has
to opt out of the tool's own convention is the wrong question.

**Why a row and not a delete key.** A keypress has no typed-fallback equivalent,
and §3.5 makes that fallback load-bearing — it is how each platform's suite drives
`configure` end to end, so a key-only action is one no suite can reach. It also
breaks the rule the whole UI rests on, that enter does what the highlighted row
says; a hidden second verb per row is what that rule exists to prevent. A row is
visible, typed-fallback-native, and has a detail column to state the cost in.

**Why the monitor keeps a question rather than gaining a `Remove` row.** A monitor
is bolted to the desk; only its assignments can be removed. The symmetry worth
having between the two menus is not a shared keystroke but a shared rule:
anything that discards configuration says what it discards and asks.

## Revision 4 — 2026-08-31

**macOS can offer the boot tier after all — the row stops being disabled.**

Sections: [`configure.md`](configure.md) §8.

**Act on (macOS only):** enable the `From boot` row and install a LaunchDaemon
in `/Library/LaunchDaemons` with `UserName` set to the installing user. Windows
already has this tier and is unaffected.

**Why the row was disabled, and why that was wrong.** It read "not available on
macOS — needs root", on the reasoning that a LaunchDaemon runs as root and the
switcher must never run as root to obtain a tier. Both halves of that were
measured wrong:

- A LaunchDaemon with `UserName` runs **as that user, unelevated**. Root is
  needed to *install* it into the system domain, not to run it — exactly the
  Windows property, where admin registers the task and nothing elevated runs on
  the switch path.
- The supporting claim that "reading the displays needs a logged-in session" was
  also wrong. Measured from a LaunchDaemon: IOKit display identity works with no
  session and no CoreGraphics, `m1ddc display list` works, and a full
  `trigger-kvm pull` works as uid 501 with no session, both writes sent.

So the tier costs one plist and a single sudo at install. No root on the switch
path, no second root-owned config, no replacement transport.

## Revision 3 — 2026-08-31

**A multi-select must obey the same layout rules as every other menu.**

Sections: [`configure.md`](configure.md) §3.1, §3.4.

**Act on:** `Select-Many` / `select_many` must lay its rows out the way
`Select-One` does — the item column, and the detail wrapped at `", "` onto
aligned continuation lines. Both implementations concatenated instead, which is
fine until the content is long, and Bluetooth device names are.

Reported from a real 80-column terminal: the trigger list overflowed, wrapped,
and the redraw corrupted — stale text from the previous frame showing at the
right edge, and the help block repeated down the screen.

Two distinct defects, one cause:

- a wrapped line's tail is **not cleared** by the next frame, so what was there
  before shows through
- a line landing exactly on the terminal's fold occupies **two** rows while the
  naive count says one, so the frame stacks downward

Also: redraw by **erasing each line to its end**, not by padding it to the
width. Padding must measure the line, and `printf`'s field width counts bytes
while a terminal column is a character — so a name containing a typographic
apostrophe (macOS puts one in every "Terry’s iPhone") pads two columns short and
leaves the previous frame showing.

Windows has the same concatenation in `Select-Many` and the same padding in
`Write-MenuFrame`; it is at revision 0 and owes this along with revisions 1–2.

## Revision 2 — 2026-08-31

**Offer a manufacturer's alternative method up front, and make esc on the top
menu move to Cancel.**

Sections: [`configure.md`](configure.md) §3.3, §6, §6.2, §10.5.
Also amends [`../AGENTS.md`](../AGENTS.md) hard rule 1b.

**Act on:**

1. **§6.2 — a new question.** When the chosen panel's EDID vendor has a
   documented alternative method, ask which method to use, immediately after the
   short name and before any input question, because the values on offer depend
   on the answer. Standard stays the default and stays the cursor's start.
   Previously the alternative was reachable only by failing the check first.

2. **§10.5 — the escalation becomes symmetric.** A panel already on the
   manufacturer method that answers nothing must be offered *standard*. Before
   this it was told "no manufacturer values are known here", which is now
   reachable, false, and a dead end.

3. **§3.3 — esc on the top menu moves the cursor to `Cancel`** rather than doing
   nothing. It must not activate it: a setup still cannot be discarded by one
   keypress.

**Why:** forcing a known-alt-mode user to fail first cost more than it bought,
and someone who saw the standard method fail without being told the alternative
existed could reasonably give up before the check offered it. The "never probed"
half of hard rule 1b is untouched — values still come only from the documented
table or from the user, and the transport gate is unchanged.

## Revision 1 — 2026-08-31

The initial corpus: [`README.md`](README.md), [`config-format.md`](config-format.md)
and [`configure.md`](configure.md), written from the finished Windows
implementation and the macOS one built to match it, and superseding
`docs/macos-parity.md`.

**Act on:** conform to every `normative` block, and to the behaviour described in
the prose around them.

- **macOS** conformed at the time this was written.
- **Windows** did not, and still does not. Two of its gaps are wording —
  §2 requires "computer", never "machine", in anything the user sees — and one
  is behaviour: §3.5 requires `configure` to accept a scripted answer stream on
  stdin, which is what makes the walkthrough testable end to end.

Run the conformance checker for the current list rather than working from one
written down here; this entry is dated and that list is not.
