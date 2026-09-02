# 003 -- dxva2 as a second Windows transport, chosen per panel at configure time

**Date:** 2026-09-01
**Status:** proposed -- measured, not built

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

**Proposed: a `dxva2` transport alongside NVAPI, selected per panel at configure
time, and confined to the login tier.** Not built by this task, which produced a
measurement and this record only.

The shape, if it is built:

- **Per panel, not per machine.** A desk can mix: this one would drive the LG
  over NVAPI (its input lives on I2C `0x50`, which the Windows DDC/CI stack
  cannot express at any GPU) and could drive the ASUS over either. The unit of
  choice is the display, matching how `method` already works in the config.
- **Chosen at configure time, offered and never probed.** Same posture as the
  manufacturer dialect in `AGENTS.md` rule 1b: the walkthrough offers the
  transport for the panel being configured, and the check offers the other one
  if the chosen one does not answer -- `specs/configure.md` §6.2 and §10.5 are
  the existing shape for exactly this, and a transport is a second axis on the
  same question, not a new kind of question.
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

## What would reopen this

Building phase 3 for real. Two things to settle then that this record does not:

- **IGCL, Intel's own I2C API, is a third transport and a separate decision.** It
  was deliberately not touched here. If it can express source `0x50`, the
  asymmetry above weakens and an LG-on-Intel desk becomes possible -- which would
  change the boot-tier consequence, not just the GPU requirement.
- **AMD was not measured at all.** dxva2 is vendor-neutral by construction, so it
  should carry, but "should" is what the top of `docs/measurements.md` exists to
  warn about. Run it in the context you are making a claim about.
