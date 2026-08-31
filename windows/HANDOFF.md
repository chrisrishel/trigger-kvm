# Handoff: Windows → macOS

**Work the macOS side owes, written from the Windows side.**

This is a **queue, not a log**. Delete an entry once macOS has landed it; git
already keeps the history. An empty file below the header means the two are in
step.

How to use it: in the macOS agent, say *"read `windows/HANDOFF.md` and bring the
implementation up to spec"*. Each entry names the spec section, so the spec is
what gets implemented — this file only explains why and points at the work.

**Do not edit the other platform from here.** You cannot run its tests or see its
hardware, and a half-made change there is worse than none.

---

## Entry format

```markdown
## A short title in the imperative

Spec:   specs/configure.md §4.2
Why:    the one-line reason, in the terms the user would use
Here:   what changed on this platform, and which test covers it
Owed:   what the other platform has to do

Anything longer goes underneath.
```

---

*(nothing outstanding)*
