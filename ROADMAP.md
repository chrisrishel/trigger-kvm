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

| route | vendor-neutral | works in session 0 | status |
|---|---|---|---|
| NVAPI | no | **yes** — measured | built |
| ADL (AMD) | no | unknown | exists; a third-party tool uses it for the LG service channel |
| IGCL (Intel) | no | **unknown — measurable on this desk** | exists, ships with the Intel driver |
| `dxva2` | **yes** | **no** — measured | proven, unbuilt |

The `dxva2` row is why the boot tier and the transport question are entangled: a
panel driven that way cannot be switched before login, because a session-0
process never sees a desktop's monitors — not even after someone logs in.

---

## Next

### N1. Measure IGCL from session 0 — the gating measurement

`ctlI2CAccess` ships with the Intel graphics driver and covers Alder Lake-P and
newer, so the UHD 770 on this desk qualifies. **If it works in session 0, there is
no boot-tier limitation on Intel systems and no watcher handover is needed there**;
`dxva2` drops from "the generalisation story" to "the fallback for AMD and older
Intel". If it does not, the handover design below is justified.

Everything else in this section is scoped by the answer, so it goes first. Known
risk: third-party reports show IGCL support varying by CPU generation.

### N2. Test the boot tier at the actual logon screen

**The only untested step in the pre-login path**, flagged in
[`ideas/nvapi-transport.md`](ideas/nvapi-transport.md) and stranded there. Every
session-0 result so far was taken with a user logged in — session 0 had no
desktop, but the machine was not empty of a session. The headline claim of the
whole boot tier has therefore never been tested in the state it exists for.

Cheap: log out, flip the switch, watch the panels, log back in and read the log.

### N3. Say plainly that the input map cannot be verified

The one item from the re-plug work that touches the dangerous case. Shared
behaviour, so it is **spec-first**. Reasoning:
[`ideas/knowing-which-input-you-are-on.md`](ideas/knowing-which-input-you-are-on.md);
task and trigger in [`TODO.md`](TODO.md).

Sequenced after N1 because both this and a transport milestone edit what `status`
reports and what `configure` asks. Specified together that is one revision bump
and one fan-out to the other platform; separately it is two, for adjacent reasons.

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

Scope is deliberately not fixed until N1 reports. The candidates:

- **A `dxva2` transport**, chosen per panel at configure time, offered and never
  probed, gated at the transport by EDID vendor+product. Shape in
  [`003`](docs/decisions/003-dxva2-as-a-second-windows-transport.md).
- **An ADL transport for AMD.** `ADL_Display_WriteAndReadI2C` is a raw I2C path,
  and a third-party tool already uses ADL to drive an LG's `0x50` / `0xF4`
  sidechannel with the same values [`displays.toml`](displays.toml) records — on
  a different LG model, which independently corroborates keying the dialect table
  on **vendor** rather than vendor:product.
- **An IGCL transport for Intel**, whose value depends entirely on N1.

**Accepted as a property of any `dxva2` panel, not a defect to fix later:** it is
login-tier only.

### The watcher handover — held

If a configured panel needs a desktop, the watcher could run in session 0 before
login and hand over to a session watcher after it, so the boot tier stays
selectable and its cost is stated truthfully rather than the row being disabled.

Held until N1, because IGCL working in session 0 would remove the need on Intel
hardware entirely. Two things to settle if it is built, both already identified:

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
