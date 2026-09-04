# 003 -- dxva2 as a second Windows transport, chosen per panel at configure time

**Date:** 2026-09-01
**Status:** accepted -- built 2026-09-02..04, and see "What was built, and what
is still unwatched" below

## Context

Decision 001 made NVAPI the single Windows transport and deleted the `dxva2`
path rather than keeping it as a dormant fallback. It named exactly what would
reopen the question: generalising to other people's hardware, where someone
whose monitors all speak **standard** DDC/CI could run on any GPU. It also asked
for the right shape in advance -- a transport *selected* for the machine and the
panel at install time, not a branch carried in the switcher.

`windows/README.md` still turns away everyone without an NVIDIA card. That is
honest today, and it is a larger exclusion than the project needs: most monitors
take the standard command. This machine has an onboard UHD 770 that can drive
one of the panels, so the question was measurable here rather than guessable.

The measurements are in `docs/measurements.md`, "The dxva2 route on the onboard
Intel GPU (Windows)", taken 2026-09-01 with the ASUS's PC cable moved from the
4090 to the motherboard HDMI output. Four results decide this:

1. **dxva2 over the Intel iGPU switches a standard panel, both directions.**
   `SetVCPFeature(0x60, ...)` moved the PG42UQ to the Mac and back, confirmed
   visually each way, 127 ms and 140 ms for a doubled send.
2. **It works from an inactive link.** The pull-back was sent while the ASUS was
   displaying the Mac, and the link remained fully enumerated -- same `hMonitor`,
   same interface path, still one physical monitor. This is the case that
   matters, because `pull` never fires from an active link.
3. **Session 0 gives it nothing.** As an unelevated S4U task, `user32` reports
   one phantom monitor named `WinDisc` with no interface path, and
   `GetNumberOfPhysicalMonitorsFromHMONITOR` fails with `0xC02625E5` -- "did not
   have any monitors associated with it". No handle, so no write, and no EDID to
   check one against.
4. **EDID vendor+product is one key across all three sources.** NVAPI, WMI and
   the dxva2 PnP interface path agree. Moving the panel between adapters changed
   its GDI name and the instance half of its PnP path but not `AUS42E0`.

Result 1 and 2 say the transport is real. Result 3 says it is desktop-bound, in
the specific way decision 001 warned about: it fails by *mis-resolving* onto a
phantom, not by erroring. Result 4 says adding it costs no second identity
mechanism.

## Decision

**Accepted: a `dxva2` transport alongside NVAPI, selected per panel at configure
time, and confined to the login tier.**

Built as described, with one correction to the shape below: `configure` offers
the transport as its own question (`specs/configure.md` §6.3), asked **before**
the §6.2 dialect question rather than as a second axis of it. The transport
decides which dialects exist at all — `dxva2` cannot express an I2C source byte,
so it cannot carry `lg-alt` — and asking the dialect first would have been a
question whose answer was already fixed. **The check does not offer the other
transport when one does not answer**, which §10.5 does for a dialect: a dialect
is a guess about a monitor, and a transport is a fact about this computer's
adapters that enumeration already settled.

The shape, as built:

- **Per panel, not per machine.** A desk can mix: this one would drive the LG
  over NVAPI (its input lives on I2C `0x50`, which the Windows DDC/CI stack
  cannot express at any GPU) and could drive the ASUS over either. The unit of
  choice is the display, matching how `method` already works in the config.
- **Chosen at configure time, offered and never probed.** Same posture as the
  manufacturer dialect in `AGENTS.md` rule 1b, and the spec draws the line that
  posture could otherwise blur: enumerating this computer's own adapters and
  reading the EDIDs they report sends nothing to a monitor, so building the offer
  from what enumerated is not a probe. Shown only where a panel enumerated on
  more than one transport; a machine with one asks nothing.
- **NVAPI stays the default where it is available for that panel**, because it
  is the one that also works in session 0.
- **Selecting dxva2 for any configured panel disables the boot tier**, drawn and
  explained, not hidden -- `specs/configure.md` §8 already specifies that shape
  and already has a precedent row for a tier that cannot be provided. The detail
  says the panel cannot be switched before login, and why.
- **The gate stays at the transport.** A dxva2 write resolves its target by EDID
  vendor+product off the interface path and refuses unless exactly one monitor
  matches -- the same refusal `Switch-Lg` makes for an ambiguous LG. The probe
  demonstrated this holds in session 0, where it matched zero and wrote nothing.
  Matching the *full* interface path, as the deleted code did, is wrong: this
  measurement broke it by moving a cable.
- **Never a fallback.** Nothing tries NVAPI and falls through to dxva2 at switch
  time. A transport is configuration, verified once by a human looking at the
  panel, exactly as an input value is.

## Consequences

- Standard-DDC panels become reachable on any GPU, which is the phase-3 prize:
  `windows/README.md` stops saying "NVIDIA required" and starts saying what is
  actually required, which is NVIDIA *for a panel whose input needs raw I2C*.
- **A stated limitation, never worked around: a dxva2 panel cannot follow a
  switch before login.** Result 3 is not a bug to route around; session 0 has no
  desktop and the phantom is what "no desktop" looks like through `user32`. A
  machine with any dxva2 panel is a login-tier machine.
- Two transports means two write paths, and decision 001's objection stands
  partly: a retained-but-unexercised path rots. The answer is that this one is
  not retained-but-unexercised -- it is only present when a user selected it for
  a panel, and selecting it runs the input check that confirms it by eye.
- **This does not help this desk**, and decision 001 said so before it was
  measured. The LG's input is on `0x50`; that needs raw I2C whatever the GPU. The
  measurement confirms the asymmetry rather than dissolving it: with the ASUS on
  the iGPU, `trigger-kvm pull` refused the ASUS by name and switched only the LG.
- `docs/measurements.md` now carries the numbers, so whoever builds this does not
  have to re-take them -- including the ones that say what was *not* measured:
  no DisplayPort motherboard output, no IGCL, nothing sent to the LG over the
  Intel route.

## What was built, and what is still unwatched

Added 2026-09-04, when the transport shipped.

**The rot objection is answered better than this record expected, and the reason
is worth recording because the record was wrong about it.** The argument above
rests on this desk having an Intel iGPU to exercise `dxva2` on -- and the plan
that built it budgeted a cable move to do so, at a real cost: the motherboard
HDMI output drives the ASUS at 3840x2160 @ 60 Hz where the 4090 drives it at
138 Hz. **That cost does not apply.** Measured 2026-09-02 with the ASUS back on
the 4090, `trigger-kvm list` reports *both* panels as reachable by `nvapi, dxva2`
and dxva2's EDID parse agrees with NVAPI exactly. `dxva2` is the Windows DDC/CI
stack and works on **any** adapter, the NVIDIA one included -- indeed
dxva2-on-the-4090 was this project's shipping path for the ASUS before commit
`70e5ed4` deleted it.

So what the 2026-09-01 cable move actually proved is the narrower claim that the
**Intel iGPU** carries DDC. That remains measured and does not need redoing. The
transport is exercisable on this desk at any time, without touching a cable,
which is a stronger answer to decision 001's "nothing would exercise it" than
"there is an iGPU we could re-cable to".

**NO PANEL HAS BEEN MOVED OVER `dxva2` SINCE IT WAS BUILT.** Every run in the
build was `-WhatIf`: both panels enumerate through both transports, dxva2's EDID
parse agrees with NVAPI (`AUS42E0` -> `0x06B3:0x42E0`, `GSM9E9D` ->
`0x1E6D:0x9E9D`), and a dxva2 `pull` resolves the ASUS to `\\.\DISPLAY2` with
value `0x11`. Nothing was sent. The 2026-09-01 readings that *did* move a panel
were taken with the earlier probe over the iGPU, not with this code. Until
somebody watches a panel move on the shipped path, that claim is not made -- hard
rule 3, and this note is here so nobody later reads "built" as "watched".

## What would reopen this

Building phase 3 for real. Two things to settle then that this record does not:

- **IGCL, Intel's own I2C API, is a third transport and a separate decision.** It
  was deliberately not touched here. If it can express source `0x50`, the
  asymmetry above weakens and an LG-on-Intel desk becomes possible -- which would
  change the boot-tier consequence, not just the GPU requirement.
- **AMD was not measured at all.** dxva2 is vendor-neutral by construction, so it
  should carry, but "should" is what the top of `docs/measurements.md` exists to
  warn about. Run it in the context you are making a claim about.
