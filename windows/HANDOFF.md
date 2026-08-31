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

## 1. Bootstrap: implement the conformance and revision checks

Kind:     spec change
Spec:     specs/README.md — "Normative wording, and how it is enforced"
Why:      until these exist, NOTHING on this side reports that the spec moved
Owed:     two checks in windows/tests/, run by run.ps1
Verified: n/a — new work

**Do this first.** Every other item here is discoverable by machine once these
exist, and undiscoverable until they do. That is the one thing a handoff cannot
delegate: a platform cannot be told it is behind by a mechanism it has not got.

**a. Conformance.** `specs/check-conformance.sh` is the macOS implementation and
the marker format is the contract — each platform writes its own checker, the
same way each writes its own transport. Read every line inside a
```` ```normative ```` fence in a spec, split each on `{placeholder}`, and assert
every remaining fragment appears in the sources.

The length rule has one subtlety, found by a mutation that survived: a **whole
line with no placeholder** is checked at any length down to 6 characters — it was
written down deliberately and `--- monitors ---` is only 16. A fragment left
**between two placeholders** carries an 18-character floor, because a short piece
of a sentence often is not distinctive. A blanket floor silently dropped every
section header and the check stayed green.

**b. Revision.** `specs/CHANGELOG.md`'s newest entry number is the spec revision.
`windows/SPEC-REVISION` records what this platform implements. The suite fails
while it is behind, naming the entries in between. This catches what the string
check cannot: a behavioural change with no new wording, and a *removed* string,
since conformance tests presence only.

## 2. Work through the revision gap

Kind:     spec change
Spec:     specs/CHANGELOG.md -- every entry above this platform's revision
Why:      several rounds of spec changes have landed since it was current
Owed:     implement them, then set windows/SPEC-REVISION to the changelog's newest
Verified: read from the specs; nothing on this platform was executed

Deliberately **not** naming the numbers here. An earlier draft of this entry said
"revisions 1 to 3" and was stale within a day. Read them instead:

```sh
sed -n 's/^revision *= *//p' windows/SPEC-REVISION
sed -n 's/^## Revision \([0-9]*\).*/\1/p' specs/CHANGELOG.md | head -1
```

Work every [`../specs/CHANGELOG.md`](../specs/CHANGELOG.md) entry above the
first number. Each says what changed, which sections, and what to act on. Once
the checks in item 1 exist, this platform's own suite reports the gap and names
the entries, and this item stops needing to be written down at all.

**For the exact list of missing strings, run the checker — do not trust a list
pasted here.** A pasted list is a snapshot of a mechanism's output and goes stale;
this one already did, between revisions 1 and 3. From the repository root, with
the macOS checker or your own:

```sh
specs/check-conformance.sh specs/configure.md \
  windows/install.ps1 windows/trigger-kvm.ps1 windows/event-watch.ps1
```

The reasoning behind each string is in the spec beside it, not here —
`configure.md` §2 for "computer, never machine", §3.5 for accepting a scripted
answer stream on stdin, §6.2 for the method choice, §10.5 for the symmetric
escalation, §3.1 and §3.4 for the wrapping that stops a multi-select corrupting
its own redraw.

## 3. `install.ps1` defines seven functions twice, and the later one wins

Kind:     defect report
Spec:     specs/configure.md §10.4 — for what the live code should be doing,
          not for what is wrong with it
Why:      the monitor check runs an older version of itself
Owed:     delete the shadowed definitions; add a duplicate-definition test
Verified: the static facts are certain, read from the file. The RUNTIME half is
          NOT: there is no PowerShell on the machine this was written from.

**This is the one item the machinery cannot find for you.** A string check proves
a string is PRESENT, not that it is REACHABLE — and here the newer wording is
present in the file and dead.

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

So the live code is the **older single-question version**, and the two-question
flow that [`specs/configure.md`](../specs/configure.md) §10.4 describes exists in
`install.ps1` but never runs.

`Test-OneComputer` (~line 2120) also calls it with `-ThisName $This`, which the
live definition does not declare. These are simple functions, so the argument
should land in `$args` and be silently discarded rather than throwing — **confirm
that before relying on it**, since whether an undeclared named parameter binds or
errors depends on simple-vs-advanced function binding and nothing here could be
executed.

What this platform owes:

1. Delete the shadowed definitions. Keep the **line 865** `Test-DisplayInput` —
   the two-question one the spec describes — and make its callers match.
2. Add a structural test for duplicate function definitions, the way macOS has
   `tests/conventions.tests.sh`.
