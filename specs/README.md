# specs -- the normative corpus

**This is what the implementations are built FROM.** Where a spec here and an
implementation disagree, the implementation is wrong. There are two
implementations of one product, `windows/` and `macos/`, sharing no code;
everything they must agree on lives here.

| file | what it settles |
|---|---|
| [`config-format.md`](config-format.md) | the flat `key = value` file both platforms read and write, and the shared fixture both readers must reproduce |
| [`configure.md`](configure.md) | the `configure` walkthrough: its UI grammar, every menu, and the two checks |
| [`detector.md`](detector.md) | the watcher: what fires, what never does, the one-shot, and what it refuses at startup |
| [`status.md`](status.md) | what `status` reports, chiefly that the input map is an assertion nothing can verify |
| [`CHANGELOG.md`](CHANGELOG.md) | behaviour changes implementations must act on, and the revision each is at |

Each fact lives in exactly one file. The hard safety rules are in
[`../AGENTS.md`](../AGENTS.md), platform hazards in `<platform>/AGENTS.md`,
measured values in [`../displays.toml`](../displays.toml), evidence in
[`../docs/measurements.md`](../docs/measurements.md), the map in
[`../ARCHITECTURE.md`](../ARCHITECTURE.md). A spec points at those; it does not
restate them.

## The verb surface

One command, and **the verbs are identical on both platforms**. Flags stay
idiomatic per platform (`-Only` on Windows, `--only` on macOS).

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

- A bare `trigger-kvm` prints the verbs, one line each, opening
  `usage: trigger-kvm <verb> [options]`, and exits 2. There is no default verb.
- **There is no `install` verb**: installing is what produced the command.
  Upgrading and repairing mean "fetch the source and run its installer", which
  works because the installer copies itself alongside the program.
- **There is no `apply` step.** Everything is read at the point it is used:
  display edits take effect on the next switch, trigger edits when the watcher
  next starts, and `restart` does that.
- Two internal verbs exist and stay off the public surface: `set --only <label>
  --value <byte>` (the walkthrough's guided discovery; a general "write any
  value" command would invite poking at monitors) and `watch` (the launcher the
  autostart entry runs).

**Why `pull` and `to` are separate verbs.** `computer.this` describes inputs on
hardware this computer is plugged into. Any other name describes inputs on
hardware it cannot observe, which go stale the moment someone moves a cable over
there. The trigger may only ever run `pull`, so a stale name can spoil a command
you typed and are watching, never an automatic switch.

## How a change flows

1. **Change the spec first.** If the new behaviour cannot be described here, it
   is not ready to implement.
2. **Implement it on the platform you are working on**, with tests.
3. **Add a [`CHANGELOG.md`](CHANGELOG.md) entry** and bump your platform's
   `SPEC-REVISION`. Leave every other platform's alone: its suite now fails and
   names what it owes.
4. **Push**, as a finished unit: spec, this platform's implementation, changelog
   entry, this platform's `SPEC-REVISION`. The other platform's suite reads its
   own checkout, so nothing above reaches it until you do. This is a standing
   exception to "do not push unasked"; force-push, amend and rebase still are
   not.

You do not change anything else in the other platform's directory. You cannot
run its tests or see its hardware, and a half-made change there is worse than
none.

## The inboxes

`<platform>/HANDOFF.md` is what that platform owes that the machinery cannot
tell it: a **defect you noticed in its code by reading it**. Anyone may append;
only that platform works through it and deletes from it. Entries carry `Kind:`
(defect report), `Spec:`, `Why:`, `Owed:` and `Verified:`, the last saying what
the author could and could not check from where they were, because a reading by
someone who cannot run that platform is a reading, not a finding.

A spec change is not an entry. It is one fact and it publishes itself: every
suite checks the same spec and the same changelog. Fan out when the message is
N different claims; publish once when it is one fact. An entry points at a
mechanism ("run the checker"), never pastes its output, which goes stale.

**The bootstrap gap.** Publishing once reaches only a platform that has
implemented the conformance and revision checks. A new implementation owes
those first; until they exist its `HANDOFF.md` has to carry what the machinery
would say, and should say so.

## Normative wording, and how it is enforced

Specs quote the wording the user sees. Blocks fenced as `normative` are
binding: every literal fragment in them must appear in each platform's sources,
and each suite checks it.

````
```normative
--- computers ---
These monitors are shared between this computer and some others.
```
````

- `{...}` marks a placeholder. The checker splits on those and compares only the
  literal fragments between them.
- A whole line with no placeholder is checked at any length down to 6
  characters. A fragment between two placeholders carries an 18-character floor.
- Lengths are measured after trimming leading and trailing whitespace.
- Normative blocks are ASCII.
- Prose outside a `normative` block describes intent and is not checked.

Mark as normative what is load-bearing: menu labels people navigate by, refusal
messages, safety text read under pressure. Not everything.

[`CHANGELOG.md`](CHANGELOG.md) is newest first, and the revision is the
**largest** `## Revision N` in it. Each implementation records the revision it
implements in its own `SPEC-REVISION`; its suite fails while that is behind and
names the entries in between, and fails if it is ahead.

[`check-conformance.sh`](check-conformance.sh) is the macOS checker
(`macos/tests/spec.tests.sh`); `windows/tests/check-conformance.ps1` the Windows
one. The marker format is the contract; each platform implements its own
checker. Each suite derives the list of spec files from `specs/*.md` (or holds
one and remembers to add to it), excluding this file and `CHANGELOG.md`.

**What the check does and does not prove.** It proves a string is present in
the sources. It is blind to a behavioural change with no new wording, to a
removed or renamed string, to a comment that happens to contain the wording, and
to a string in a shadowed definition (Windows pairs it with a duplicate-definition
scan; bash's last definition wins and the macOS suite sources the real files, so
it needs none). The revision ledger and the shared fixtures in
`config-format.md` close the gaps that matter; a behavioural fixture for the
walkthrough is the next step (`ROADMAP.md`).
