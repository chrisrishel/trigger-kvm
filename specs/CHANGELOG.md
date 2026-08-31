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

## Why this exists alongside the conformance check

The conformance check already tells every platform when the spec adds a string
it does not have. It is blind to two things, and this closes them:

- **Behavioural changes with no new wording** — "the cursor lands on the first
  check rather than Save" has nothing to grep for.
- **Removed or renamed strings** — the check tests presence only, so a platform
  keeps old wording forever and stays green.

---

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
