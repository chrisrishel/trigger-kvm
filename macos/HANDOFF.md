# Handoff: macOS → Windows

**Work the Windows side owes, written from the macOS side.**

This is a **queue, not a log**. Delete an entry once Windows has landed it; git
already keeps the history. An empty file below the header means the two are in
step.

How to use it: in the Windows agent, say *"read `macos/HANDOFF.md` and bring the
implementation up to spec"*. Each entry names the spec section, so the spec is
what gets implemented — this file only explains why and points at the work.

**Do not edit the other platform from here.** You cannot run its tests or see its
hardware, and a half-made change there is worse than none.

---

## 1. Three normative strings are missing

Found by running the conformance checker against the Windows sources from a Mac:

```sh
specs/check-conformance.sh specs/configure.md \
  windows/install.ps1 windows/trigger-kvm.ps1 windows/event-watch.ps1
```

```
MISSING: ran out of input. configure needs a terminal, or a complete script of answers.
MISSING: Which devices move to this computer when you flip the switch?
MISSING: Flip your switch to this computer -- the monitors should follow.
3 of 106 normative fragments from specs/configure.md are missing
```

### 1a. "computer", never "machine", in anything the user sees

Spec: [`specs/configure.md`](../specs/configure.md) §2 (Voice).

The config key is `computer.this` and the walkthrough asks what to call THIS
computer, so the term must not change between them. `install.ps1` has **four**
user-facing strings still saying "machine":

| where | current | should be |
|---|---|---|
| `Read-Triggers` | `Which devices move to this machine when you flip the switch?` | `...to this computer...` |
| the closing message | `Flip your switch to this PC -- the monitors should follow.` | `...to this computer...` |
| `discover` | `=== displays on this machine ===` | `=== displays on this computer ===` |
| `status` | `machines : {0}` | `computers: {0}` |

macOS already reads "computer" throughout; its 7 remaining uses of "machine" are
all in code comments referring to a physical machine, which is correct.

### 1b. `configure` must accept a complete script of answers on stdin

Spec: [`specs/configure.md`](../specs/configure.md) §3.5 (The typed fallback).

Windows refuses up front when `Test-CanPrompt` is false, which includes a
redirected stdin. The spec canonises the macOS behaviour instead: the typed
fallback is a supported way to drive `configure`, and running **out** of answers
is what stops it.

Why the macOS reading won: it is what makes the walkthrough testable end to end,
which the original brief asked for in its own §8. Windows' suite drives the flow
by stubbing `Read-Host` rather than by redirecting stdin, so it never exercises
the real input path.

What Windows owes: keep refusing where there is genuinely no way to ask (the
elevated relaunch runs in a hidden window — that case is real and must stay), but
let a redirected stdin through, and stop with this message when the answers run
out rather than re-asking forever:

```
ran out of input. configure needs a terminal, or a complete script of answers.
```

---

## 2. `install.ps1` defines seven functions twice, and the later one wins

**Not a spec change — a defect found while writing the spec.** Reported here
because this is the file the Windows agent reads.

```
Add-ToUserPath         274  379
Get-UserPath           272  377
Remove-FromUserPath    284  389
Request-Elevation      230  335
Send-Input             843  928
Set-ConfigValue        305  410
Test-DisplayInput      865  950
```

PowerShell takes the **later** definition. For six of these the two bodies look
equivalent, so the duplication is only clutter. **`Test-DisplayInput` is not**:

| | line 865 — dead | line 950 — live |
|---|---|---|
| params | `... $Current, $ThisName` | `... $Current, [switch]$IsMachine` |
| asks | `Did the {0} change to {1}, and back to {2}?` then `Did the {0} change at all?` | `What did the {0} do?`, one menu of four |

So the live code is the **older single-question version**. The design note that
replaced it — *"One question with four answers made the reader hold every failure
in mind at once to find their own"* — is now
[`specs/configure.md`](../specs/configure.md) §10.4, and the two-question flow it
describes exists in `install.ps1` but never runs. (That reasoning came from
`docs/macos-parity.md` §5.7, retired once its normative content moved into
`specs/`; `git log` has it.)

There is a second consequence. `Test-OneComputer` (~line 2120) calls it with
`-ThisName $This`, which the live definition does not declare. These are simple
functions, so the argument lands in `$args` and is silently discarded rather than
erroring — which is why nobody noticed. The effect is that the prompt says "the
input for THIS computer is wrong" instead of naming the computer.

**I could not run PowerShell to confirm the runtime behaviour** — no PowerShell
on this machine, and not that hardware. The static facts above are certain; the
"lands in `$args` rather than throwing" half depends on simple-vs-advanced
function binding, so verify it before relying on it.

What Windows owes:

1. Delete the shadowed definitions. Keep the **line 865** `Test-DisplayInput`
   (the two-question one the spec describes) and delete the line 950 one, then
   make its callers match.
2. Add a structural test for duplicate function definitions, the way macOS has
   `tests/conventions.tests.sh`. A string-level conformance check **cannot** catch
   this: the newer wording is present in the file, just unreachable.

---

## 3. Implement the conformance check in the Windows suite

Spec: [`specs/README.md`](../specs/README.md) — "Normative wording, and how it is
enforced".

`specs/check-conformance.sh` is the macOS implementation. The **marker format is
the contract**; each platform implements its own checker, the same way each
implements its own transport. A PowerShell equivalent belongs in
`windows/tests/`, run by `run.ps1`, so a spec edit fails the Windows suite until
the implementation catches up.

It needs to: read every line inside a ```` ```normative ```` fence, split each on
`{placeholder}`, drop fragments shorter than 18 characters, and assert every
remaining fragment appears in the sources.
