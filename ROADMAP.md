# Roadmap

Where this project has been and where it is going, at milestone granularity.
Task-level detail lives in [`TODO.md`](TODO.md) (durable) and `.context/PLAN.md`
(this session, disposable).

This file holds **trajectory and status only**. Every fact it refers to lives
somewhere else and is not restated here: the evidence in
[`docs/measurements.md`](docs/measurements.md), the reasoning in
[`docs/decisions/`](docs/decisions/), the exploration in [`ideas/`](ideas/), the
contracts in [`specs/`](specs/README.md), the map in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

**On the phase numbers.** "Phase 1", "phase 2a/2b", "phase 3" were used in
commits, decision records and idea notes before this file existed, and were never
defined anywhere. They are reconstructed below from those references. Where a
label is an inference rather than something the repo states outright, it says so.

---

## Done

### Phase 1 — a pre-login tier needs no relay (Windows)

Proved NVAPI **enumerates and identifies** displays from session 0: as SYSTEM, as
an unelevated S4U task, and from an at-startup task after a cold boot. The prize
was architectural — no relay process into the user's session, which is what makes
the boot tier cheap.

Phase 1 deliberately sent nothing, so it could not answer whether *writing* also
worked; that was tested separately and does (the S4U task moved the LG in both
directions with no desktop). Enumerating is not writing, and the two were proved
apart on purpose — now a standing rule in [`AGENTS.md`](AGENTS.md).

**1c** established that S4U registration is denied to a standard user, which is
why the boot tier costs admin once to register while running unelevated.

### Phase 2a — the LG onto an in-process, aimed NVAPI write *(label inferred)*

Replaced `lg-input-switch.exe`, whose `_i2c_write` sprayed every connected output
and ports 0-7, with `NvDdc.WriteLgInput`: one function, no source byte in its
signature, refusing any panel whose EDID manufacturer is not GSM. An aimed write
has no blast radius, so the `Test-LgBlastRadius` guard went with it. This is
hard rule 5's gate. *The repo never labels this "2a"; the number is inferred from
decision 001 placing it before phase 2b.*

### Phase 2b — one transport for both panels (Windows)

Moved the ASUS from `dxva2.dll` onto the same aimed NVAPI I2C write and deleted
the `dxva2`/`user32` code rather than keeping it as a dormant fallback. The
switcher gained no desktop dependency and the two panels differ only in a source
byte and VCP code. Reasoning and the cost accepted:
[`docs/decisions/001`](docs/decisions/001-nvapi-as-the-only-windows-transport.md).

### macOS to parity

Both tiers (LaunchDaemon with `UserName`, LaunchAgent), Bluetooth and USB
detection, and the finding that display identity needs no session at all.

### Measured, deliberately not built

Two routes proven on hardware and left unimplemented, each with a decision record
saying what it would take and what would reopen it:

| route | record | why not built |
|---|---|---|
| Intel-Mac framebuffer I2C | [`004`](docs/decisions/004-intel-mac-ddc-proven-not-built.md) | keeps *old* hardware alive; `README.md` says Apple Silicon because that is what is supported |
| Windows `dxva2` on any GPU | [`003`](docs/decisions/003-dxva2-as-a-second-windows-transport.md) | proposed, and now being reconsidered — see below |

---

## The transport landscape, as currently understood

This reframing is recent and is what the next phase turns on. The old frame was
"NVIDIA versus everyone else". The real split is **vendor-specific raw I2C, which
works without a desktop**, versus **vendor-neutral `dxva2`, which does not**.

| route | vendor-neutral | needs admin to write | works in session 0 | status |
|---|---|---|---|---|
| NVAPI | no | no | **yes** — measured | built |
| ADL (AMD) | no | not documented | unknown | exists; a third-party tool uses it for the LG service channel |
| IGCL (Intel) | no | **yes — documented** | moot | **ruled out**, [`005`](docs/decisions/005-igcl-ruled-out-by-its-elevation-requirement.md) |
| `dxva2` | **yes** | no | **no** — measured | proven, unbuilt |

The `dxva2` row is why the boot tier and the transport question are entangled: a
panel driven that way cannot be switched before login, because a session-0
process never sees a desktop's monitors — not even after someone logs in.

The IGCL row is settled and was the surprise. Every IGCL write path requires
administrator privileges, and it exposes no input-select API that avoids raw
I2C — so it cannot run on a switch path that is unelevated by construction, and
whether it works in session 0 no longer matters.

---

## Next

### ~~N1. Measure IGCL from session 0~~ — answered 2026-09-02, without measuring

Closed on a cheaper observation, on a different axis than expected: **IGCL
requires admin for every write**, and offers no input-select API that avoids raw
I2C. It cannot sit on an unelevated switch path, so the session-0 question is
moot. [`005`](docs/decisions/005-igcl-ruled-out-by-its-elevation-requirement.md).

Consequences, which run *opposite* to what this entry assumed: `dxva2` is the
generalisation story rather than a fallback, the boot-tier limitation on Intel
hardware is permanent, and **the watcher handover is more likely to be needed,
not less.**

### ~~N2. Test the boot tier at the actual logon screen~~ — passed 2026-09-02

The last untested step in the pre-login path, and it holds. Twice, 30 minutes
apart, both with no interactive user on the machine at all: the session-0 watcher
detected a USB arrival, fired `pull`, and the panels came back to the PC,
confirmed by eye. The first run (01:00) could only witness the ASUS move, because
the Mac's video leg to the LG was unplugged; the second (01:30) was the full
round trip with that cable connected — **both panels to the Mac, both back** —
between a logoff at 01:30:02 and the next logon at 01:30:52. Evidence, and the
false-edge hypothesis each had to rule out first, in
[`docs/measurements.md`](docs/measurements.md).

So the boot tier now delivers what it was built for, measured rather than argued:
**a rebooted or logged-out PC can take its own displays back with nobody signed
in.** Nothing in the design changes; a claim stops being provisional.

Two incidental findings of the same runs: the second watched device is on the
switch after all, absorbed by the settle rather than the debounce — which closes
the question the 2026-09-01 detector entry left open for macOS — and a departure
is `Write-Verbose`, so correlating a flip against the log needs the OS's PnP
arrival timestamps rather than the log alone.

### ~~N3. Say plainly that the input map cannot be verified~~ — landed 2026-09-02

`status` now shows the input map and states that nothing can verify it, with the
recovery (`configure`) beside the warning. Idea **D** of
[`ideas/knowing-which-input-you-are-on.md`](ideas/knowing-which-input-you-are-on.md)
— the only option that helps the panel which fails dangerously, since detection
is barred rather than unimplemented.

Spec-first, in the new [`specs/status.md`](specs/status.md): status had no
normative home before this, and the map's unverifiability is shared behaviour,
not a Windows detail. Revision 8; Windows implements it, macOS owes it.

**The roadmap said to bundle this with a transport milestone** to save a revision
bump and one fan-out. That argument was written while the transport milestone
might have been IGCL-shaped and small. N1 ruled IGCL out, so the milestone is now
the `dxva2` build — large and open-ended — and bundling would have parked a
safety-legibility item behind it. Specifying `dxva2` without building it is worse
still: it would leave macOS owing conformance strings for something nobody
implemented. Two bumps, taken deliberately.

Found and fixed alongside it, because it lives in the same command: **`status`
could not see a boot-tier watcher at all** and reported none while one was
running and firing. It now asks the single-instance lock instead of counting
processes, which an unelevated caller cannot do across a session boundary.
Evidence in [`docs/measurements.md`](docs/measurements.md).

---

## Phase 3 — generalisation, and its open shape

The standing meaning of "phase 3": running on other people's hardware rather than
this desk. Decision 001 named it as the thing that would reopen the transport
question, and it now has.

**What changed.** Decision 001's strongest objection to a second transport was
that it would rot — *"nothing would exercise it, and this project's safety rests
on things being verified rather than assumed."* That was true when non-NVIDIA
hardware here was hypothetical. This desk now has a working Intel iGPU that will
stay enabled, so a second transport can be exercised on demand. The objection is
answered by a change in circumstances, not by being argued away.

**Why this is not decision 004's situation.** Intel-Mac support keeps *old*
hardware alive. A vendor-neutral or multi-vendor Windows transport stops
excluding *current mainstream* hardware — every AMD desktop, every Intel laptop,
anything without an NVIDIA card, all of which `windows/README.md` turns away
today. Different in kind, not degree.

With N1 answered, the scope narrows to one certain piece and one open one:

- **A `dxva2` transport — BUILT on Windows, 2026-09-04.** `transport` is now a
  config key and a separate axis from `method` (`specs/CHANGELOG.md` revision 9):
  chosen per panel at configure time, offered and never probed, gated at the
  transport by EDID vendor+product, and never a fallback. `configure` asks only
  where a panel enumerated on more than one transport, disables the boot tier for
  a panel `dxva2` would strand, and `status` says which panel that is.
  [`003`](docs/decisions/003-dxva2-as-a-second-windows-transport.md) is accepted.
  **Not yet watched on the shipped path**: every run so far was `-WhatIf`, so
  under hard rule 3 no claim is made that a panel has moved over it. macOS owes
  only the refusal rule — it is not required to invent a second transport.
- **An ADL transport for AMD** — open. `ADL_Display_WriteAndReadI2C` is a raw
  I2C path, and a third-party tool already uses ADL to drive an LG's `0x50` /
  `0xF4` sidechannel with the same values [`displays.toml`](displays.toml)
  records — on a different LG model, which independently corroborates keying the
  dialect table on **vendor** rather than vendor:product. Its docs state no
  privilege requirement, but that is weaker than Intel's explicit one and there
  is no AMD hardware here to measure. It would matter because, unlike `dxva2`, a
  raw-I2C route can reach a sidechannel panel *and* may work in session 0.
- ~~An IGCL transport for Intel~~ — ruled out,
  [`005`](docs/decisions/005-igcl-ruled-out-by-its-elevation-requirement.md).

**Accepted as a property of any `dxva2` panel, not a defect to fix later:** it is
login-tier only. On Intel hardware that is now the only option, so it is the
whole story there.

### The watcher handover — no longer held

If a configured panel needs a desktop, the watcher could run in session 0 before
login and hand over to a session watcher after it, so the boot tier stays
selectable and its cost is stated truthfully rather than the row being disabled.

This was held pending N1, on the theory that IGCL might remove the need on Intel
hardware. It does not, so the question is live: on any machine with a `dxva2`
panel, a handover is the only way the boot tier covers anything at all. Whether
that earns its complexity is the open design call — the alternative remains the
disabled row that [`specs/configure.md`](specs/configure.md) §8 already provides
for. Two things to settle if it is built, both already identified:

- The general form is *"the watcher runs in the context its configured transports
  need, decided at configure time"* — which collapses to exactly today's
  behaviour on an all-NVAPI desk, so it adds nothing there.
- **The 1-minute self-heal makes the naive logoff answer wrong.** A watcher that
  exits at login leaves the self-heal launching a process every minute for the
  whole session to check one API call and quit. It needs a real session-change
  trigger, or a dormant-not-exited watcher.

---

## Deferred, with triggers

Each of these is waiting on a specific event, not on someone getting round to it.
The trigger is the point.

| item | trigger | where it lives |
|---|---|---|
| Capabilities read (`0xF3`/`0xE3`) | a third-party standard-DDC monitor is actually in the room | [`ideas/unknown-monitor-discovery.md`](ideas/unknown-monitor-discovery.md) |
| The advanced escape hatch | someone reports a panel answering neither standard DDC nor a known dialect | `TODO.md` |
| Boot tier on a real standard account | such an account exists, or someone reports it failing | `TODO.md` |
| Intel-Mac DDC | see the record's own conditions | [`004`](docs/decisions/004-intel-mac-ddc-proven-not-built.md) |
| Directory-scoped `AGENTS.md` | `windows/AGENTS.md` needs a rule and has no room | `TODO.md` |
| Same-GPU, different-port re-plug | next time the machine is open | `TODO.md` |

---

## Accepted limitations

Not backlog. Each is a deliberate property, recorded where the reasoning is, and
listed here so nobody mistakes one for an oversight.

- **Wake is not a trigger and must not become one.** Sleep and wake fire nothing
  on either platform. The consequence is accepted: **drift while the machine is
  awake strands you until the switch next moves.** ([`AGENTS.md`](AGENTS.md))
- **A switch can only be confirmed by a human looking at the screen.** No verify,
  no read-back, no retry loop.
- **The input map is an assertion about cabling the tool cannot check.** N3 makes
  that legible; nothing can make it detectable.
- **The LG needs raw I2C whatever the GPU**, because its input lives on I2C
  source `0x50` and the Windows DDC/CI stack cannot express that address. So no
  vendor-neutral tier will ever cover this particular desk.
