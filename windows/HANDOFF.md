# Handoff — work the Windows side owes

**This is an INBOX.** Anyone may append an entry; only the Windows side works
through it, and only the Windows side deletes from it.

Read this first when you start work here. It is a **queue, not a log** — delete
an entry once it has landed, because git already keeps the history. Nothing
below the format section means the two platforms are in step.

## The rule it lives under

You never *change* anything in the other platform's directory: not its code, not
its tests, not its docs. You cannot run its tests or see its hardware, and a
half-made change there is worse than none.

**Appending an entry to its `HANDOFF.md` is the one exception**, and it is a
different verb from editing — prose cannot break their build. That is how work
crosses the boundary.

## Entry format

```markdown
## A short title, in the imperative

Kind:     spec change | defect report
Spec:     specs/configure.md §4.2          (or: n/a)
Why:      the one-line reason, in the terms the user would use
Owed:     what this platform has to do
Verified: what the author could and could not check from where they were

Anything longer goes underneath.
```

`Kind` matters because the two have different standing:

- A **spec change** is required. The conformance check already fails here until
  it lands.
- A **defect report** is a reading, often by someone who could not run this
  platform's code. `Verified` says how far they got. Disagree with it if you
  have better evidence — you can run it and they could not.

---

## Mirror the instruction-file byte check, and re-point what now lives in windows/AGENTS.md

Kind:     defect report
Spec:     n/a -- see docs/decisions/002-instruction-files-for-two-agents.md
Why:      Codex reads at most 32,768 bytes of the AGENTS.md chain and truncates
          the rest silently; the root file was 53 KB, so Codex never saw
          "Build and test" or "Conventions" on either machine
Owed:     (1) add to `windows/tests/conventions.tests.ps1` the check that
          `macos/tests/conventions.tests.sh` now runs -- root `AGENTS.md`
          <= 20480 bytes, `windows/AGENTS.md` <= 10240, their sum <= 30720,
          and every `CLAUDE.md` begins with `@AGENTS.md`. (2) Re-point the
          references that say "see ..\AGENTS.md" for content that has moved:
          `grep -n AGENTS.md windows\*.ps1 windows\README.md` and check each --
          the Bluetooth/presence, abandoned-mutex, phantom-monitor and
          sleep/wake entries are now in `windows/AGENTS.md`, their dated
          evidence in `docs/measurements.md`; hard rules 1-5 are still in the
          root file, so those references are unchanged.
Verified: sizes measured here 2026-08-31 and the macOS suite already enforces
          BOTH chains' budgets, so nothing is unprotected -- what Windows lacks
          is finding out on its own machine. `windows/AGENTS.md` and
          `windows/CLAUDE.md` were created from the root file's Windows-specific
          entries with the user's explicit permission (repo management, not
          Windows development); nothing else under `windows/` was touched. The
          Windows suite was not run from here.
