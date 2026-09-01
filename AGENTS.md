# Agent instructions

Read this before changing anything in this repo. Start with `ARCHITECTURE.md` for
the design and `displays.toml` for the values. Then read the `AGENTS.md` of the
platform you are working in -- `macos/AGENTS.md` or `windows/AGENTS.md` -- which
holds that platform's hazards. The dated evidence behind every rule below is in
`docs/measurements.md`; the rules are here, the measurements are there.

## What this project is

Two machines (Mac Studio, Windows PC) share two monitors with **no KVM in the video
path**. Each machine connects directly to both monitors. A USB switch moves the
peripherals; whichever machine receives them commands both monitors over DDC to
select its own inputs.

Every platform implementation is the same two roles: a **detector** (do I own the
peripherals now?) and a **switcher** (make the monitors show me).

## Hard safety rules

**1. Never sweep or brute-force VCP codes on I2C source address `0x50`.**
That is a service/factory channel. Sweeping it has bricked LG monitors -- the
`ddcutil` repo carries an issue titled "Bricked LG Monitor". Use only the values
already documented in `displays.toml`. If you need a value that isn't there, ask;
do not go looking for it experimentally.

**1a. A monitor's inputs are named after the COMPUTERS on them, and that one map
answers both verbs.** `display.lg.input.0xD1 = mac`, `computer.this = pc`. `pull` is
`to <computer.this>`; same lookup, same code path. There is no `scene.*` and no
`display.<label>.self` -- both were deleted, because two representations of "machine
M is on input V of display D" can disagree and one cannot. `to` is still MANUAL
ONLY: a trigger may never reach a name other than `computer.this`, because a name
describes hardware this machine cannot observe.

**1b. A manufacturer dialect is OFFERED, never probed.** The dialect table is
keyed by EDID **vendor** -- never vendor:product, which was one row per monitor
someone here happened to own. Values in it come from documentation and
measurement, never from a search, a sweep or a range.

Standard DDC/CI is the DEFAULT for every panel, whatever the make. Where the
vendor has a documented alternative, the walkthrough offers the choice up front
once that panel is being configured, and the check offers it again -- in either
direction -- if the chosen method turns out not to answer. See
`specs/configure.md` sections 6.2 and 10.5.

"Never probed" is the half that stops monitors being bricked: values come only
from the table or from what the user types in that moment, and the transport
gate (rule 5) refuses a manufacturer channel to a panel whose EDID vendor does
not match. Blind value-walking is standard-DDC-only, one MCCS value at a time,
offered with its cost stated, and refused when it would take the last display.
(This rule once required standard DDC/CI to fail first; why that changed is
`specs/CHANGELOG.md` revision 2.)

**2. Never verify a switch by reading a VCP value back.**
Reads are unreliable on both monitors and *have already produced false negatives*:

- **PG42UQ** returns `0` for luminance, contrast, volume **and** `max luminance` --
  always, whether or not it is the active input. Writes still work perfectly.
- **LG** returns real values on a settled active link, but `-7` while the link is
  inactive or renegotiating. It read `-7` immediately after a switch that had in
  fact succeeded, then recovered to `100` seconds later.

Writes are fire-and-forget. Do not build verify-then-retry loops; they will fire
spurious retries. Do not probe immediately after a switch.

**3. You cannot see the screen. A switch is only confirmed by a human looking at
it.** Never report that a switch worked because a command returned success or a
read looked right -- both have lied here. Ask the user to confirm visually, and say
plainly when something is unverified.

**4. Never leave the user without a working display.** Switching both monitors to
the other machine blacks out this one. When testing, move one monitor at a time and
keep the other on the machine running the terminal. Warn before any command that
takes the last remaining display. Because the link stays enumerated, a window on a
monitor you just switched away is still *there*, just invisible -- before moving the
monitor the terminal is on, have the user drag the terminal to the other one first.

**5. The LG service channel may only ever be aimed at the LG.**
I2C source `0x50` carries VCP `0xF4`, and what that means on a non-LG panel is
unknown. The rule is enforced in code, at the transport, not by caller discipline:
on each platform exactly ONE function can emit source `0x50`, the source byte is
not a parameter, and it refuses unless the target's EDID manufacturer is GSM
(`0x1E6D`). There is no generic "write to source N" entry point, so no caller can
aim it at another vendor's panel, including by accident. Do not add one. Each
platform's `AGENTS.md` names its gate, and each suite must assert the gate is the
only door (macOS does; Windows owes it -- see its `HANDOFF.md`).

The switcher also refuses the LG switch unless exactly one enumerated output
identifies as the LG -- zero is a refusal, and so is more than one, because an
ambiguous target cannot be aimed at safely.

**Expect the LG to flicker briefly on every LG switch, including a re-assert to the
input it is already on.** It is re-negotiating the link, and each write is sent
twice by design (the bus is lossy). This is normal and was mistaken for a fault
once already -- do not go looking for a bug in it.

## Rules both platforms share

None of these is a bug to fix on sight. Each has a measurement behind it in
`docs/measurements.md`; re-measure before changing the detector rather than
reasoning from a plausible premise (that file opens with the three claims that
were once "measured" here and were wrong).

- **The detector fires on an absent -> present EDGE, debounced and settled, and
  the debounce is load-bearing** -- a single physical plug produces dozens of
  events on Windows, not one. **Usually only one device appears in the log, and
  that is correct**: both watched devices arrive together, whichever lands first
  fires, the other falls inside the debounce window. A second `pull` on one flip
  means the other device arrived outside that window; harmless. Do not "fix"
  either, and do not read a single-device log as the other device being
  misconfigured.
- **The watcher is ONE process with N event sources.** Never add a second
  persistent process, and never tell users to run one: two watchers each hold
  their own debounce and both fire on the same arrival. That includes a hotkey --
  "it can just run `pull`" is true and means a second background app to install
  and supervise. Sources differ in what constitutes a fire (presence needs
  debounce and settle; a hotkey needs neither); what they share is the process
  lifetime, the single-instance lock, and the fire.
- **Whatever the source, it runs `pull` -- never another computer's name.**
- **Wake is not a trigger, and must not become one.** Sleep/wake fires nothing
  on either platform (measured). What sleep breaks is the *monitors*: a panel
  with auto-input enabled defects to the other live signal, and that is closed by
  one OSD setting per monitor, recorded in `displays.toml` and `README.md`. Do
  not add a wake trigger instead -- macOS dark wakes (Power Nap, Time Machine,
  network) would re-assert constantly, and displays that steal themselves at
  random is the worst failure this system can have. Known gap, accepted: drift
  while the machine is *awake* still strands you until the switch next moves.
- **Both switchers address exactly one display**, resolved by EDID at runtime.
- **The LG's EDID product id is per-input, so it is not a shared constant.** Three
  values have been measured on the one panel. Each host sees a stable value for
  its own input, so it works as a *local* key; copying one host's value to
  another, or treating `displays.toml`'s field as authoritative, silently matches
  nothing.
- **Both platforms rotate their log at watcher startup, after the single-instance
  lock, and nowhere else** -- so a redundant start never rotates while a watcher
  is alive, and the switcher (a separate process writing the same file) can never
  race it mid-switch. macOS must rotate by truncating; see `macos/AGENTS.md`.
- **When it starts is a property of the HOST, not the switcher.** Post-login is
  the DEFAULT on both platforms; both also offer a boot tier that runs UNELEVATED
  as the user (admin/root registers it, nothing elevated runs on the switch path).
  Do not change which is the default without asking -- no-admin is a deliberate
  posture. Nothing in a switcher or watcher knows or asks when it was started; if
  one ever needs to, the abstraction is wrong. Installing either tier removes the
  other -- by the shared task name on Windows, and explicitly on macOS, where a
  launchd label is per domain and both can otherwise coexist.
- **Enumerating is not writing. Do not generalise from one to the other.** Each
  was proved separately before the pre-login tier was claimed.

## Keep the docs current

Documentation is part of the change, not a follow-up. **In the same commit as the
code**, update whichever of these the change affects:

| File | Update when |
|---|---|
| `README.md` | The front door changes -- what it does, install, or the top-level gotchas |
| `ARCHITECTURE.md` | The *shape* changes -- components, data flow, a design decision or its rationale. Not for detail churn. |
| `displays.toml` | Any monitor, input value, DDC method, or trigger device changes |
| `macos/README.md`, `windows/README.md` | That platform's install, components, or behaviour changes |
| `AGENTS.md` | A new constraint every session on either platform must respect |
| `<platform>/AGENTS.md` | A new constraint or hazard specific to that platform |
| `docs/measurements.md` | A dated observation on hardware or a platform that a rule now rests on |
| `specs/*.md` | Any behaviour BOTH platforms must share changes -- and this happens FIRST, before the implementation |
| `specs/CHANGELOG.md` | A behaviour change implementations must act on -- and bump your own `SPEC-REVISION` in the same commit |
| `<platform>/HANDOFF.md` | That platform's INBOX, for what its own tests cannot tell it -- chiefly a defect you found in its code. NOT for spec changes. Only that platform deletes from it. |

Two specific obligations:

- **`displays.toml` is a contract across two independent implementations.** Changing
  a value there means changing every implementation to match, in the same commit.
  A value fixed on one machine and not the other produces a half-switching setup
  that presents as a hardware fault.
- **When a doc's claim stops being true, fix it in that commit.** Stale docs here
  are actively dangerous -- this repo's docs encode which values are safe to send to
  a service channel.

## specs/ is normative -- change it FIRST

`specs/` is what the implementations are built FROM. **Where a spec and an
implementation disagree, the implementation is wrong.** Start at `specs/README.md`.
It exists because there are two implementations of one flow sharing no code.

**A change to anything specified there happens in this order, and the order is
the point:**

1. **Change the spec first.** If you cannot describe the new behaviour there, it
   is not ready to implement.
2. **Implement it on the platform you are working on**, with tests.
3. **Add a `specs/CHANGELOG.md` entry and bump YOUR platform's `SPEC-REVISION`.**
   Leave every other platform's alone: their suites now fail and name what they
   owe, which is how they find out without being told.
4. **PUSH IT.** Nothing above reaches another platform until you do.

**Publishing is the push, not the commit.** The other platform's suite reads ITS
checkout, so an unpushed changelog entry leaves it green and unaware. **Push
anything addressed to another platform** -- `specs/`, `specs/CHANGELOG.md`, an
entry appended to its `HANDOFF.md` -- as a finished unit (spec, this platform's
implementation, changelog entry, this platform's `SPEC-REVISION`), never a bare
spec edit. This is a standing policy that overrides "do not push without being
asked". Still no force-push, amend or rebase without asking; platform-local work
is pushed only when asked.

**DO NOT CHANGE ANYTHING IN THE OTHER PLATFORM'S DIRECTORY** -- not its code, not
its tests, not its docs. You cannot run its tests or see its hardware, and a
half-made change there is worse than none. **Appending an entry to its
`HANDOFF.md` is the one exception**: prose cannot break their build.

A `HANDOFF.md` is an **INBOX** -- what THAT platform owes -- for what the machinery
CANNOT tell it, chiefly a DEFECT YOU NOTICED IN ITS CODE by reading it. **A spec
change does NOT go there**: it is one fact and publishes itself through the
changelog and the conformance check. Fan out when the message is N different
claims; publish once when it is one fact. Only that platform works through its
inbox and deletes from it; entries carry `Kind:` and `Verified:`. The entry
format and the reasoning are in `specs/README.md`.

**Read your own platform's HANDOFF.md before starting work there, AND RUN YOUR
PLATFORM'S SUITE.** The handoff is only half the inbox: a spec change appears as
two failing tests -- the conformance check naming the strings you are missing, and
the revision check naming the changelog entries you owe.

**This is enforced, not merely asked for**: each suite runs a self-tested
conformance check and a revision check against `specs/CHANGELOG.md`, paired with
a structural check for duplicate definitions (a string can be PRESENT and
unreachable). What the checks prove, their blind spots and the bootstrap gap for
a new implementation are in `specs/README.md`.

**What does NOT go in a spec.** Each fact lives in exactly one file, because two
representations of one fact can disagree and one cannot. The hard safety rules and
the rules every session needs stay in THIS file; platform hazards in that
platform's `AGENTS.md`; measured values in `displays.toml`; the high-level map in
`ARCHITECTURE.md`. A spec may point at them; it may not restate them. New docs
earn their existence when their job arises, not before.

## The instruction files have a byte budget

Two agents work this repo: Claude Code, which loads `CLAUDE.md` and its
`@AGENTS.md` import, and Codex, which loads the `AGENTS.md` chain from the git
root down to its working directory and **truncates it silently at 32,768 bytes**
(measured; `docs/decisions/002-instruction-files-for-two-agents.md`).

So: this file holds what every session needs (cap 20 KB); `macos/AGENTS.md` and
`windows/AGENTS.md` hold that platform's hazards (10 KB each); dated evidence goes
to `docs/measurements.md`, never here. Every `CLAUDE.md` is an `@AGENTS.md` import
plus Claude-specific additions only -- never a second copy, because copies drift.
`macos/tests/conventions.tests.sh` fails when any root-plus-platform chain exceeds
the budget. When you add a rule, move evidence out rather than raising the cap:
both vendors document that adherence drops as these files grow.

## Build and test

Each platform's `AGENTS.md` carries the hazards of its toolchain and how to
exercise its watcher without installing. The commands:

```sh
cd macos
make                                      # build event-watch and display-probe
make test                                 # shellcheck + the suite; no hardware needed
make mutate                               # reintroduce each bug the suite should catch
make install / status / logs / uninstall

trigger-kvm pull                          # pull configured monitors here
trigger-kvm to pc                         # point them at the computer "pc" (manual)
trigger-kvm pull --only asus              # one monitor only -- use when testing
trigger-kvm pull --dry-run                # resolve + print packets, send nothing
trigger-kvm discover / status / restart / logs / pause
```

```powershell
cd windows
.\install.ps1                              # install, register the task, start
.\install.ps1 -AddToPath                   # ...and put `trigger-kvm` on PATH
trigger-kvm configure / status / discover / restart / logs / pause / uninstall
trigger-kvm configure -Fresh               # ask everything again, pre-fill nothing
.\trigger-kvm.ps1 pull                     # pull configured monitors to this machine
.\trigger-kvm.ps1 to mac                   # point them at the machine "mac" (manual)
.\trigger-kvm.ps1 pull -Only asus          # one monitor only -- use when testing
.\trigger-kvm.ps1 pull -WhatIf             # resolve + print packets, send nothing
cd windows\tests; .\run.ps1                # the suite; no hardware needed
```

Both suites run without hardware and cannot move a monitor. Add to the suite when
you change anything, then MUTATE the thing you changed and confirm the new test
fails. `pause`, never kill/stop -- each platform's `AGENTS.md` says why.

## Conventions

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, scoped by
  platform where useful (`feat(macos): ...`).
- **Do not hardcode display indices or UUIDs in switching code.** Resolve by EDID
  at runtime -- index numbers shift (the two indices have swapped on the Windows
  machine; `docs/measurements.md`), and index `1` silently becoming the *other*
  monitor would send LG service-channel writes to the ASUS. **Do not write a
  mapping down anywhere and treat it as stable**, including in scratch notes; a
  stale one is worse than none. Neither an index nor a description string is a
  usable key; the EDID manufacturer and product read off the output is.
- Keep `.ps1` files ASCII-only. Windows PowerShell 5.1 reads a `.ps1` with no BOM
  as ANSI, so a UTF-8 em dash in a comment surfaces as a parse error at an
  unrelated line. Prose files are unaffected.
- Send DDC writes more than once. They are idempotent and the bus is lossy.
- **Machine-local facts belong in the generated config, not in the scripts.**
  Which panels are here, their EDID ids, methods and input values live in the
  per-machine config. `displays.toml` keeps the *researched, cross-machine*
  knowledge -- which methods and VCP codes a monitor model needs, and which values
  are safe to send it. Do not push discovered, per-desk facts back into either the
  scripts or `displays.toml`.
