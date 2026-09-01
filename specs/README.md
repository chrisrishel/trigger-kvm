# specs — the normative corpus

**This is what the implementations are built FROM.** Where a spec here and an
implementation disagree, the implementation is wrong.

There are two implementations of one product — `windows/` and `macos/` — sharing
no code. Everything they must agree on lives here.

| file | what it settles |
|---|---|
| [`config-format.md`](config-format.md) | the flat `key = value` file both platforms read and write |
| [`configure.md`](configure.md) | the `configure` walkthrough: its UI grammar, every menu, and the two checks |
| [`CHANGELOG.md`](CHANGELOG.md) | behaviour changes implementations must act on, and the revision each is at |

## What does NOT belong here

Each fact lives in exactly one file. Two representations of one fact can
disagree, and one cannot — which is why `scene.*` and `display.<label>.self`
were both deleted from this project.

| it belongs there | not here |
|---|---|
| [`../AGENTS.md`](../AGENTS.md) | the hard safety rules, and every hazard learned on hardware |
| [`../displays.toml`](../displays.toml) | measured values — EDID ids, input values, VCP codes, packets |
| [`../ARCHITECTURE.md`](../ARCHITECTURE.md) | the stable, high-level map: components and data flow |
| `windows/README.md`, `macos/README.md` | how that platform does it, and why |

A spec may *point* at those. It may not restate them.

## The verb surface

One command, and **the verbs are identical on both platforms**, because they are
typed daily on both machines. Flags stay idiomatic per platform — `-Only` on
Windows, `--only` on macOS — because forcing one spelling into the other means
hand-parsing arguments and losing the shell's own binding and completion.

```
trigger-kvm pull                 point every configured monitor at THIS computer
trigger-kvm to <computer>        point them at another, by name. MANUAL ONLY
trigger-kvm list                 connected displays, with their identifiers
trigger-kvm configure            the walkthrough
trigger-kvm configure --fresh    ...pre-filling nothing
trigger-kvm status               autostart, what that covers, version, config
trigger-kvm discover             what is attached, in the form the config wants
trigger-kvm restart              make a hand-edited config take effect now
trigger-kvm logs                 tail the log
trigger-kvm pause                stand the watcher down to test by hand
trigger-kvm uninstall
```

**There is no `install` verb**, deliberately: installing is what produced the
command. Upgrading and repairing both mean "fetch the source and run its
installer", which works because the install is self-contained — the installer
copies itself, so managing and removing keep working after the source tree is
gone.

**There is no `apply` step.** Everything is read at the point it is used. Display
edits take effect on the next switch; trigger edits when the watcher next
starts, and `restart` does that.

`set --only <label> --value <byte>` exists as an internal verb for the
walkthrough's guided discovery. It is deliberately kept off the public verb
surface: a general "write any value" command invites poking at monitors, which
is the habit `AGENTS.md`'s first hard rule exists to discourage.

### Why `pull` and `to` are separate verbs

Not style. `computer.this` describes inputs on hardware this computer is plugged
into and can be sure of. Any other name describes inputs on hardware it **cannot
observe**, which go stale the moment someone moves a cable over there. **The
trigger may only ever run `pull`** — so a stale name can spoil a command you
typed and are watching, never an automatic switch.

## How a change flows

A change to anything specified here happens **in this order**, and the order is
the point:

1. **Change the spec first.** If you cannot describe the new behaviour here, it
   is not ready to implement.
2. **Implement it on the platform you are working on**, with tests.
3. **Add a [`CHANGELOG.md`](CHANGELOG.md) entry** and bump your platform's
   `SPEC-REVISION`. Leave every other platform's alone — their suites now fail,
   which is how they find out.
4. **Push it.** Their suites read their checkout, so none of the above reaches
   them until you do — see [`../AGENTS.md`](../AGENTS.md), "Publishing is the
   push, not the commit."

`<platform>/HANDOFF.md` is an **inbox** — what that platform owes. Anyone may
append; only that platform works through it and deletes from it, so crossing a
finished item off always happens in your own directory, and an agent finds its
own work without being told where to look.

You do **not** change anything else in the other platform's directory. You cannot
run its tests or see its hardware, and a half-made change there is worse than
none. Appending to its queue is a different verb from editing it: prose cannot
break their build.

### What goes in a HANDOFF.md, and what does not

A `HANDOFF.md` is for what the machinery **cannot** tell a platform — chiefly a
**defect you noticed in its code by reading it**. Nothing on that side will ever
surface it on its own.

A **spec change does not go there.** It is one fact, and it publishes itself:
every platform's suite already checks the same spec, so they all learn at once
and none of them can be forgotten. Appending to every other platform's inbox
would be N−1 edits per change, worse with each platform added, and silent if one
is missed.

> **Fan out when the message is N different claims. Publish once when it is one
> fact.**

"Check whether your implementation has this bug too" is genuinely N separate
claims, each of which may not apply — that one fans out, and it is rare enough
to be fine.

When you do write an entry, mark whether it is a spec change or a defect report,
and say what you could and could not verify from where you were: a defect report
written by someone who cannot run that platform is a reading, not a finding.

### The bootstrap gap

Publishing once only reaches a platform that has **implemented the checks**. A
platform without them cannot be told it is behind by a mechanism it has not got,
and nothing will surface the gap on its own.

So **the first thing any implementation owes is the conformance and revision
checks themselves** — before conforming to anything else. Until they exist, that
platform's `HANDOFF.md` has to carry what the machinery would otherwise say, and
should say plainly that it is doing so.

Windows was the case that made this concrete: `windows/SPEC-REVISION` sat at 0
against a changelog at 3, and nothing in `windows/tests/` would report either
fact, so its `HANDOFF.md` carried a paragraph saying so on the machinery's
behalf. It has both checks now — `windows/tests/check-conformance.ps1` and
`windows/tests/spec.tests.ps1` — its own suite reports its own gap, and that
paragraph is deleted. Both implementations are level.

### Point at mechanisms, not at their output

A handoff entry says *run the checker*; it does not paste the checker's list.
A pasted list is a snapshot of something that changes, it goes stale silently,
and it is the same duplication that `specs/` exists to prevent — the one in
`windows/HANDOFF.md` rotted within two revisions of being written.

## Knowing you are behind

The conformance check tells a platform when the spec adds a string it does not
have. It is blind to two things:

- **a behavioural change with no new wording** — nothing to grep for
- **a removed or renamed string** — the check tests presence only, so old wording
  survives and the suite stays green

[`CHANGELOG.md`](CHANGELOG.md) closes both. Its newest entry number is the spec
revision; each implementation records the revision it implements in its own
`SPEC-REVISION`; each platform's suite fails while that is behind, and names the
entries in between. Nobody has to be told, and a third implementation costs
nothing.

## Normative wording, and how it is enforced

Specs quote the wording the user sees. Blocks fenced as `normative` are
**binding**: every literal fragment in them must appear in each platform's
sources, and each platform's test suite checks it.

````
```normative
--- computers ---
These monitors are shared between this computer and some others.
```
````

- `{...}` marks a placeholder. The checker splits on those and compares only the
  literal fragments between them, so formatting differs freely per platform.
- A **whole line** with no placeholder is checked at any length down to 6
  characters: it was written down deliberately and is distinctive enough.
  `--- monitors ---` is 16 characters and cannot match by accident.
- A fragment left **between two placeholders** carries an 18-character floor,
  because a short piece of a sentence often is not distinctive.
- Prose outside a `normative` block describes intent and is not checked.

Mark as normative what is **load-bearing**: menu labels people navigate by,
refusal messages, and safety text read under pressure. Do not mark everything,
or the spec becomes brittle and editing it becomes miserable.

[`check-conformance.sh`](check-conformance.sh) is the macOS checker, run by
`macos/tests/spec.tests.sh`. The *marker format* is the contract; each platform
implements its own checker, the same way each implements its own transport.

**What the check does and does not prove.** It proves a string is present in the
sources. It does not prove that string is *reachable* — a shadowed function can
still contain it. That gap is real and has already bitten this project once, in
`windows/install.ps1`, where a duplicate definition left the older wording live
and the newer wording dead in the same file. Pair the string check with a
structural check for duplicate definitions.
