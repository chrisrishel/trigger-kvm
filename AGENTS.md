# Agent instructions

Read this first. Then read the `AGENTS.md` of the platform you are working in
(`macos/`, `windows/`), which holds that platform's hazards and build commands,
and run that platform's suite: it names anything the specs now owe you.
`ARCHITECTURE.md` is the map, `specs/` the contract, `displays.toml` the safe
values, `docs/measurements.md` the dated evidence behind every rule here. Rules
live here; evidence lives there.

Two computers share two monitors with no KVM in the video path. A USB switch
moves the peripherals; whichever computer receives them commands both monitors
over DDC/CI to select its own inputs. Each platform is a **detector** (do I own
the peripherals now?) and a **switcher** (make the monitors show me).

## Hard safety rules

**1. Never sweep, probe or brute-force VCP codes or values on I2C source `0x50`.**
It is a service channel; sweeping it has bricked LG monitors (`ddcutil` issue
#419, "Bricked LG Monitor"). Send only values in `displays.toml` or typed by the
user in that moment. If you need a value that is not there, ask.

**1a. A monitor's inputs are named after the COMPUTERS on them, and that one map
answers both verbs.** `display.lg.input.0xD1 = mac`; `pull` is `to
<computer.this>`, same lookup, same code path; there is no second table
(`specs/config-format.md`). `to <other>` is MANUAL ONLY: a trigger runs `pull`
and nothing else, because another computer's inputs are hardware this computer
cannot observe.

**1b. A manufacturer dialect is OFFERED, never probed.** Standard DDC/CI is the
default for every panel. The dialect table is keyed by EDID vendor and filled from
documentation and measurement only, never a search, sweep or range. The
walkthrough offers the alternative up front and the check offers it again, either
way (`specs/configure.md` 6.2, 10.5). Blind value-walking is standard-DDC-only,
one MCCS value at a time, cost stated, refused when it would take the last
display.

**2. Never verify a switch by reading a VCP value back.** Reads lie on both
panels and have produced false negatives here (`docs/measurements.md`, "DDC
reads"). Writes are fire-and-forget: no verify-then-retry loops, no probe right
after a switch.

**3. You cannot see the screen.** A switch is confirmed only by a human looking
at it; a success code or a read is not evidence. Ask, and say plainly what is
unverified.

**4. Never leave the user without a working display.** Move one monitor at a
time, keep the other on the computer running the terminal, and warn before any
command that takes the last one. A window on a monitor you switched away is still
there, invisible: have the user drag the terminal over first.

**5. The LG service channel (`0x50`, VCP `0xF4`) may only ever be aimed at the
LG, and the gate is in the transport, not in callers.** Every function that can
emit source `0x50` takes no source byte and refuses unless the target's EDID
manufacturer is GSM (`0x1E6D`). There is no generic "write to source N"; do not
add one. A platform's shipping path has exactly ONE such function; a
never-installed, not-built-by-default instrument may carry its own under the same
gate (decision 004). Each platform's `AGENTS.md` names EVERY emitter, and its
suite asserts, self-testedly and in every language in the tree, that there are no
others. The switcher refuses the LG switch unless exactly one enumerated output is
the LG.

**The LG flickers on every LG switch, including a re-assert to the input it is
on.** Link renegotiation, and each write is sent twice on purpose. Not a bug.

## Rules both platforms share

Each rests on a measurement in `docs/measurements.md`, whose opening lists
"measurements" that were wrong. Re-measure before changing a detector rule.

- **The detector fires on an absent -> present EDGE, debounced and settled**
  (`specs/detector.md`). One plug is dozens of events on Windows. Usually only
  ONE device appears in the log per flip: both arrive together and the second is
  absorbed by the settle or the debounce. That is correct, and a second `pull` is
  harmless.
- **The watcher is ONE process with N event sources**, never a second persistent
  process, hotkey apps included (`ARCHITECTURE.md`, "one process").
- **Wake is not a trigger and must not become one.** Sleep/wake fires nothing on
  either platform; what sleep breaks is a monitor with auto-input on, fixed by one
  OSD setting (`README.md`). Dark wakes would re-assert at random, the worst
  failure this system can have. Accepted gap: drift while awake strands you
  until the switch next moves.
- **Resolve a display by EDID at runtime, never by index, UUID or description.**
  Indices have swapped here, and index 1 becoming the other panel aims `0x50` at
  the ASUS. Write no mapping down, not even in notes.
- **The LG's EDID product id is per-INPUT** (four values measured), so it is a
  local key only: never copy one host's value to another. The serial is stable
  across inputs; the CoreGraphics UUID is not.
- **The log rotates at watcher startup, after the single-instance lock, and
  nowhere else** (`specs/detector.md`; macOS by truncation, see
  `macos/AGENTS.md`).
- **When it starts is the HOST's property.** `From boot` is the highlighted row;
  a headless or declined install falls back to login. The boot tier runs
  UNELEVATED as the user, and installing either tier removes the other
  (`specs/configure.md` 8). Do not change either default without asking. Nothing
  in a watcher or switcher knows when it was started. Enumerating and writing
  from the boot tier were proved separately; do not infer one from the other.
- **`displays.toml` is the allowlist, and nothing reads it.** Its values live in
  both platforms' dialect tables. A change there lands with THIS platform's table
  in the same commit; the other platform's table is an entry in its `HANDOFF.md`,
  never an edit here. Per-desk facts (which panels are here, their ids and
  values) live in the generated config, never in the scripts or in
  `displays.toml`.

## Changing shared behaviour

`specs/` is normative: where a spec and an implementation disagree, the
implementation is wrong. The flow is `specs/README.md`, "How a change flows":
spec first; implement on YOUR platform, with tests; add the changelog entry and
bump YOUR `SPEC-REVISION` only; then push. The other platform's suite reads its
own checkout, so anything addressed to it (`specs/`, its `HANDOFF.md`) is pushed
as a finished unit, a standing exception to "do not push unasked" (never
force-push, amend or rebase unasked). Never change anything in the other
platform's directory; appending a defect report to its `HANDOFF.md` is the one
exception, and a spec change is never one of those.

## Keep the docs current, in the same commit

| File | Update when |
|---|---|
| `README.md`, `<platform>/README.md` | what it does, install, behaviour or gotchas change |
| `ARCHITECTURE.md` | the SHAPE changes: components, data flow, a decision |
| `ROADMAP.md` / `TODO.md` | a milestone lands / a task is deferred, with its trigger |
| `displays.toml` + this platform's dialect table | a documented model, value or method changes |
| `AGENTS.md` / `<platform>/AGENTS.md` | a new constraint for every session / for that platform |
| `docs/measurements.md` | a dated observation a rule now rests on |
| `specs/*.md`, `specs/CHANGELOG.md` | shared behaviour changes: FIRST, then the code |

A claim that stops being true is fixed in that commit: these docs encode which
values are safe to send to a service channel.

## Conventions

- **Comments and docs describe the code as it is.** What and why, in a few
  lines, pointing at the spec, measurement or decision that holds the reasoning.
  No "it used to", no incident narrative, no argument with an earlier version:
  git holds the history, `docs/measurements.md` the evidence, `docs/decisions/`
  the trade-offs. This is pre-release; a diary is clutter.
- Conventional commits, scoped by platform: `feat(macos): ...`.
- `.ps1` files are ASCII-only: PowerShell 5.1 reads a BOM-less file as ANSI.
- DDC writes are sent more than once; they are idempotent and the bus is lossy.
- Add a test for what you change, then MUTATE it and watch the test fail
  (`make mutate`, `tests\mutate.ps1`). `pause` a watcher, never kill it.
- The instruction files have a byte budget, enforced by both suites: this file
  20 KB, each platform file 10 KB, because Codex truncates the `AGENTS.md` chain
  silently at 32 KiB (decision 002). Every `CLAUDE.md` is `@AGENTS.md`, nothing
  more. To add a rule, move its evidence out; never raise the cap.
