# 004 -- The Intel-Mac DDC route: proven, deliberately not built

**Date:** 2026-09-01
**Status:** accepted; capability proven, transport declined

## Context

The macOS switcher reaches monitors through `m1ddc`, which uses `IOAVService`,
an interface Intel Macs do not have. Intel Macs expose DDC/CI through the
framebuffer's I2C interface. Measured 2026-09-01 from a MacBook Pro 16" with
`macos/intel-ddc-probe`: every operation the two shipping switchers perform was
performed from an Intel Mac, both panels, both channels (standard `0x60` and
the LG's `0xF4` on source `0x50`), both directions, each confirmed by a person
looking. Readings in `docs/measurements.md`, "Intel DDC route".

## Decision

Do not build it. Keep the instrument that proved it and this record, so the
work can be resumed mechanically.

Intel support would not be a third platform: it is the same macOS
implementation with an arch switch inside one function. The cost is
verification. It would put code paths in the tree that can only be exercised on
a machine that is not a daily driver and has to be cabled to two monitors to
test, so every future macOS change would force a choice between shipping an
unverified branch and staging hardware. That is a recurring tax for a machine
nobody works on.

**Revisit when** an Intel Mac becomes a machine someone actually works on at
this desk.

## What the route needs, if built

- **Three seams.** The one arch-dependent line is the `"$M1DDC" display ...`
  call inside `ddc_send` (`macos/lib/display.sh`), which becomes a tool chosen
  once by `uname -m`; the arch preflight in `macos/install.sh` becomes
  conditional; the `M1DDC` harness seam in `macos/tests/lib.sh` is renamed. The
  Intel binary presents `m1ddc`'s CLI (`display <uuid> set input|input-alt
  <value>`), so `ddc_send` stays the one gate and the arch picks the tool, never
  the policy.
- **Identity.** `CGDisplayGetDisplayIDFromUUID`, then
  `CGDisplayVendorNumber`/`CGDisplayModelNumber`, matched against each
  framebuffer's `IODisplayCreateInfoDictionary`; re-resolved on every
  invocation. `display-probe`'s EDID walk finds no `EDID` property on Intel (it
  is `IODisplayEDID` there), so its connector and name fields come back empty.
- **The wire.** Slave `0x6E`, source byte is payload byte 0, checksum `0x6E`
  XOR every preceding byte. `IOI2CRequest` for a write: `sendAddress = 0x6E`,
  `sendTransactionType = kIOI2CSimpleTransactionType`, `replyTransactionType =
  kIOI2CNoTransactionType`, `replyBytes = 0`. Reads add `replyAddress = 0x6F`,
  `replySubAddress = 0x51`, `minReplyDelay = 30 ms`,
  `replyTransactionType = kIOI2CDDCciReplyTransactionType`.
  `kIOI2CCombinedTransactionType` is 3, not 4.
- **Traps, all measured.** A vacant framebuffer returns a non-null empty
  dictionary and advertises DDC; require an EDID. `result == 0` proves nothing
  (the internal panel returns garbage with `0x0`); only `6E 88` framing
  distinguishes an answer. The gMux moves a display between framebuffers on
  hotplug; never cache a framebuffer handle. Read values lie exactly as hard
  rule 2 says.
- **The door count.** `tests/conventions.tests.sh` asserts `0x50` appears in
  exactly one non-comment line across `macos/*.c`, which today is the
  instrument's. A shipping Intel tool either removes the instrument's emitter or
  grows out of the instrument. Hard rule 5 permits the instrument's emitter only
  while it is never installed, not built by default, gated the same way and
  covered by the same scan.
- **Unknown.** The 13" 2019 MacBook Pro drives externals from the Intel GPU (a
  different framebuffer driver whose bus advertised no DDCci bit); no-session
  operation on Intel; the LG's `hdmi1`/`hdmi2` sidechannel values, deliberately
  absent from the instrument's allowlist.

## The code

`macos/intel-ddc-probe.c` is the executable half of this record: excluded from
`make all`, never installed, its two emitters the ones proven above.
`README.md` keeps saying Apple Silicon, because that is what is supported.
