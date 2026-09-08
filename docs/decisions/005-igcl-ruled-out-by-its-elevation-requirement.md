# 005 -- IGCL is ruled out by its elevation requirement

**Date:** 2026-09-02
**Status:** accepted

## Context

Whether Intel's control library (IGCL) could reach a display from session 0 was
going to gate the Windows generalisation work: a driver-level route might work
where `dxva2` cannot, which would put Intel-driven panels in the boot tier.

The measurement was never needed. Intel's `igcl_api.h` states on every
write-capable structure (`ctl_i2c_access_args_t`,
`ctl_i2c_access_pinpair_args_t`, `ctl_aux_access_args_t`): *"for Write
operation, App needs to run with admin privileges"*. And the installed
`ControlLib.dll` exports 130 `ctl*` symbols, none matching `input`, `source`,
`vcp`, `select` or `switch`: a monitor's input select is reachable only through
those raw I2C and AUX calls.

## Decision

No IGCL transport, now or as a fallback. Elevation is needed once, to register,
and nothing elevated runs on the switch path (`AGENTS.md`); a transport whose
every write needs admin cannot sit on it. Whether it works in session 0 is moot.

This rests on Intel's documentation, not a reading taken here, and
`docs/measurements.md` deliberately has no entry for it: a documented
requirement to elevate is a design fact, adverse whether or not the current
driver enforces it.

## Consequences

- `dxva2` is the Windows generalisation story, not a fallback.
- A panel on an Intel GPU is login-tier only, permanently.
- AMD's ADL (`ADL_Display_WriteAndReadI2C`) documents no privilege requirement,
  which is weaker evidence than Intel's explicit one; it stays open in
  `ROADMAP.md`.

## What would reopen this

Intel documenting an unprivileged write path or an input-select API that is not
raw I2C; or the project accepting an elevated component on the switch path,
which is a posture change needing its own record.
