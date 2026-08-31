# specs — the normative corpus

**This is what the implementations are built FROM.** Where a spec here and an
implementation disagree, the implementation is wrong.

There are two implementations of one product — `windows/` and `macos/` — sharing
no code. Everything they must agree on lives here.

| file | what it settles |
|---|---|
| [`config-format.md`](config-format.md) | the flat `key = value` file both platforms read and write |
| [`configure.md`](configure.md) | the `configure` walkthrough: its UI grammar, every menu, and the two checks |

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
3. **Append an entry to the OTHER platform's `HANDOFF.md`** saying what changed,
   which spec section, why, and what it now owes.

`<platform>/HANDOFF.md` is an **inbox** — what that platform owes. Anyone may
append; only that platform works through it and deletes from it, so crossing a
finished item off always happens in your own directory, and an agent finds its
own work without being told where to look.

You do **not** change anything else in the other platform's directory. You cannot
run its tests or see its hardware, and a half-made change there is worse than
none. Appending to its queue is a different verb from editing it: prose cannot
break their build.

The same route carries a **defect you noticed in their code**, not just a spec
change. Mark which it is, and say what you could and could not verify from where
you were — a defect report written by someone who cannot run that platform is a
reading, not a finding.

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
