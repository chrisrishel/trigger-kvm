# 005 -- IGCL is ruled out by its elevation requirement

**Date:** 2026-09-02
**Status:** accepted

## Context

`ROADMAP.md` made one measurement gate the whole of phase 3: whether Intel's
control library (IGCL) can reach a display from **session 0**. The reasoning was
that IGCL is a driver-level interface rather than a desktop one, so it might work
where `dxva2` provably cannot -- and if it did, an Intel-driven panel could sit in
the boot tier, no watcher handover would be needed on Intel hardware, and `dxva2`
would drop from "the generalisation story" to "a fallback for AMD and older
Intel".

That measurement was never taken, because a cheaper observation killed the
hypothesis first, on a different axis entirely.

**IGCL requires administrator privileges for every write.** From Intel's own
`igcl_api.h`, the same sentence on all three write-capable structures --
`ctl_i2c_access_args_t`, `ctl_i2c_access_pinpair_args_t` and
`ctl_aux_access_args_t`:

> `ctl_operation_type_t OpType; ///< [in] Operation type, 1 for Read, 2 for
> Write, for Write operation, App needs to run with admin privileges`

`ctl_panel_descriptor_access_args_t` carries the same requirement, and adds that
only Read is currently supported there. IGCL's own introduction is consistent:
*"administrator users have permissions to perform control operations on
resources."*

**And there is no higher-level route that avoids it.** The installed
`ControlLib.dll` on this machine exports 130 `ctl*` symbols, and **not one** of
them matches `input`, `source`, `vcp`, `select` or `switch`. IGCL exposes
brightness, scaling, sharpness, LACE, wire format, retro scaling, overclocking,
fans, LEDs, ECC and firmware -- but a monitor's input select is reachable only
through raw I2C (`ctlI2CAccess`, `ctlI2CAccessOnPinPair`) or AUX
(`ctlAUXAccess`). All three are the structures quoted above.

## Decision

**No IGCL transport.** Not now, and not as a fallback.

The project's posture is stated in `AGENTS.md` and is not negotiable for this:
**elevation is needed once, to register, and nothing elevated runs on the switch
path.** A transport whose every write needs admin would require the *switcher* to
run elevated on every switch, forever. `AGENTS.md` already forbids offering that
as a tier -- *"A tier that required the switcher itself to run as root would not
be this tier and must not be offered as it"* -- and neither existing tier could
carry it: the boot tier is S4U at `RunLevel Limited` by design, and the login
tier is an ordinary user process.

So the session-0 question is moot. Even if IGCL enumerated and wrote perfectly
with no desktop, it could not be used unelevated, and the tiers are unelevated by
construction.

## Consequences

- **`dxva2` is the generalisation story for Windows, not a fallback.** There is
  no Intel-specific route that beats it, so phase 3's transport work is
  `dxva2` plus, possibly, AMD's ADL. See
  [`003`](003-dxva2-as-a-second-windows-transport.md).
- **The boot-tier limitation stands for Intel hardware and is now permanent.** A
  panel on an Intel GPU is switchable only through `dxva2`, which needs a
  desktop. IGCL was the one candidate that might have lifted that, and it cannot.
- **The watcher handover is therefore more likely to be needed, not less** --
  the opposite of what the roadmap expected when it held that design pending this
  answer. `ROADMAP.md` is updated accordingly.
- One transport to build rather than a per-vendor zoo, which is simpler than the
  branch this was exploring.

## On not measuring it

This rests on Intel's documentation, not on a reading taken here, and
`docs/measurements.md` is deliberately not given an entry: it holds observations
of real hardware, and its own preamble warns against filing inferences there.

The measurement was not needed, and would not change the decision if taken.
Suppose an unelevated `ctlI2CAccess` write happened to succeed on this driver
today: relying on it would mean building a switch path on undocumented behaviour
in a privileged operation, against the vendor's explicit statement of the
contract. That is precisely the kind of assumption this project refuses
elsewhere. A documented requirement to elevate is a *design* fact, and it is
adverse whether or not the current implementation enforces it.

Taking it would also have cost a cable move: IGCL only sees displays on the Intel
adapter, and the ASUS is back on the 4090.

## What would reopen this

- **Intel documenting an unprivileged write path**, or shipping an input-select
  API that is not raw I2C.
- **The project accepting an elevated component on the switch path.** That is a
  posture change, not a technical one, and it would need its own decision record
  arguing why the no-elevation stance was wrong -- not a note in this one.

## AMD, for contrast -- open, not decided

AMD's ADL exposes `ADL_Display_WriteAndReadI2C` and
`ADL_Display_DDCBlockAccess_Get`, and its public documentation states **no**
privilege requirement. That is weaker evidence than Intel's explicit statement:
absence of a documented requirement is not a documented absence, and no AMD
hardware exists here to measure. ADL therefore stays an open question in
`ROADMAP.md` rather than following IGCL out.
