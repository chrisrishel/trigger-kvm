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

## Revision 1 — 2026-08-31

The initial corpus: [`README.md`](README.md), [`config-format.md`](config-format.md)
and [`configure.md`](configure.md), written from the finished Windows
implementation and the macOS one built to match it, and superseding
`docs/macos-parity.md`.

**Act on:** conform to every `normative` block, and to the behaviour described in
the prose around them.

- **macOS** conforms — 149 of 149 fragments.
- **Windows** has three outstanding items, listed in
  [`../windows/HANDOFF.md`](../windows/HANDOFF.md). Two are wording
  (`computer`, never `machine`) and one is behaviour (`configure` must accept a
  scripted answer stream on stdin). Bump `windows/SPEC-REVISION` to 1 once they
  land.
