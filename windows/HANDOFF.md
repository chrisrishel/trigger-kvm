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

## 1. Three normative strings are missing

Kind:     spec change
Spec:     specs/configure.md §2 (Voice), §3.5 (The typed fallback)
Why:      the two platforms say different things for the same step
Owed:     the four wording fixes in 1a, and the stdin behaviour in 1b
Verified: run from a Mac against the Windows sources, so the strings are
          certain; nothing was executed

Found by pointing the conformance checker at the Windows sources from a Mac —
possible from here even though running the Windows suite is not:

```sh
specs/check-conformance.sh specs/configure.md \
  windows/install.ps1 windows/trigger-kvm.ps1 windows/event-watch.ps1
```

```
MISSING: ran out of input. configure needs a terminal, or a complete script of answers.
MISSING: Which devices move to this computer when you flip the switch?
MISSING: Flip your switch to this computer -- the monitors should follow.
3 of 149 normative fragments from specs/configure.md are missing
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

Kind:     defect report
Spec:     specs/configure.md §10.4 (the four outcomes) — for what the live code
          should be doing, not for what is wrong with it
Why:      the monitor check runs an older version of itself
Owed:     delete the shadowed definitions; add a duplicate-definition test
Verified: the static facts are certain — read from the file. The RUNTIME half is
          NOT: I have no PowerShell here. Treat the `$args` claim below as a
          reading to confirm, not a finding.

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

**Confirm the runtime half before relying on it.** Whether an undeclared named
parameter lands in `$args` or throws depends on simple-vs-advanced function
binding, and I could not execute anything to find out.

What Windows owes:

1. Delete the shadowed definitions. Keep the **line 865** `Test-DisplayInput`
   (the two-question one the spec describes) and delete the line 950 one, then
   make its callers match.
2. Add a structural test for duplicate function definitions, the way macOS has
   `tests/conventions.tests.sh`. A string-level conformance check **cannot** catch
   this: the newer wording is present in the file, just unreachable.

---

## 3. Implement the conformance check in the Windows suite

Kind:     spec change
Spec:     specs/README.md — "Normative wording, and how it is enforced"
Why:      a spec edit currently fails only the macOS suite
Owed:     a PowerShell checker in windows/tests/, run by run.ps1
Verified: n/a — new work

`specs/check-conformance.sh` is the macOS implementation. The **marker format is
the contract**; each platform implements its own checker, the same way each
implements its own transport. A PowerShell equivalent belongs in
`windows/tests/`, run by `run.ps1`, so a spec edit fails the Windows suite until
the implementation catches up.

It needs to: read every line inside a ```` ```normative ```` fence, split each on
`{placeholder}`, and assert every remaining fragment appears in the sources.

The length rule has one subtlety, and it was found by a mutation that survived. A
**whole line with no placeholder** is checked at any length down to 6 characters —
it was written down deliberately and is distinctive enough, and
`--- monitors ---` is only 16. A fragment left **between two placeholders**
carries an 18-character floor, because a short piece of a sentence often is not
distinctive. A blanket floor silently dropped every section header in the spec
and the check stayed green.
