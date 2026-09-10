# 003 -- dxva2 as a second Windows transport, chosen per panel at configure time

**Date:** 2026-09-01
**Status:** accepted; built 2026-09-04. **No panel has yet been watched moving
over the shipped path** (every run was `-WhatIf`); the 2026-09-01 readings that
moved a panel used a probe, not this code. Hard rule 3: "built" is not "watched".

## Context

Decision 001 deleted `dxva2` and named the reopening condition: other people's
hardware, where every monitor speaks standard DDC/CI and an NVIDIA card is an
exclusion the project does not need. This machine's onboard UHD 770 made the
question measurable (`docs/measurements.md`, "The dxva2 route"):

1. `SetVCPFeature(0x60, ...)` over the Intel iGPU moved the PG42UQ both ways,
   confirmed visually, including from an inactive link (the case `pull` always
   fires from).
2. In session 0, `user32` reports one phantom monitor named `WinDisc` with no
   interface path and no physical-monitor handle. No handle, no write, no EDID.
   Measured again 2026-09-08 in the other shape: over Remote Desktop `user32`
   reports the RDP virtual display and none of the physical panels, so `dxva2`
   identifies nothing and refuses. **"Confined to the login tier" is therefore
   too weak -- it is confined to a LOCAL CONSOLE session**, and a remote desktop
   is a logged-in session by every other measure.
3. EDID vendor+product is one key across NVAPI, WMI and the dxva2 PnP interface
   path; moving the panel between adapters changed its GDI name and PnP instance
   but not `AUS42E0`.
4. `dxva2` works on any adapter, the 4090 included, so it is exercisable on this
   desk without touching a cable.

## Decision

A `dxva2` transport beside `nvapi`, **per panel**, **chosen at configure time
and never a fallback**, **confined to a local console session**.

- `configure` asks for the transport (`specs/configure.md` 6.3) before the
  dialect question, and only where a panel enumerated on more than one
  transport; enumerating adapters and reading EDIDs sends nothing to a monitor,
  so it is not the probing hard rule 1b forbids. NVAPI is the default where
  available because it also works in session 0.
- Selecting `dxva2` for any configured panel disables the `From boot` row,
  drawn and explained; `status` names the panel it strands.
- The gate stays at the transport: a dxva2 write resolves by EDID vendor+product
  off the interface path and refuses unless exactly one monitor matches. The
  full interface path is not the key; a cable move changes it.
- Nothing tries `nvapi` and falls through to `dxva2` at switch time. The packet
  that moved the panel on the day somebody watched it is the packet sent
  afterwards.

## Consequences

- Standard-DDC panels are reachable on any GPU. What Windows requires is NVIDIA
  *for a panel whose input needs raw I2C*, or wherever there is no local console
  session.
- A `dxva2` panel cannot follow a switch from session 0, nor from a Remote
  Desktop session. Stated, not worked around.
- The `lg-alt` + `dxva2` pair is refused by name; the stack cannot express the
  source byte, so this transport cannot widen the `0x50` surface.
- This does not help this desk: the LG needs `0x50`.

## What would reopen this

- IGCL turned out to need admin for every write and is ruled out (005).
- AMD was not measured; `dxva2` is vendor-neutral by construction, but "should
  carry" is what `docs/measurements.md`'s preamble warns about.
