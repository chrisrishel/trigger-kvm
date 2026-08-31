# Idea: an NVAPI transport to replace lg-input-switch

**Status:** enumeration half proven on this machine 2026-08-30 in four contexts (see
Measured, below). Write half **built** and living in `windows/switch-displays.ps1`;
see "The write path, as built". This note stays as the reference for the ids, the
struct traps and the framing fork.

## Why

The Windows LG path used to shell out to `lg-input-switch.exe`, which cannot be
aimed: it loops every connected output mask against ports 0-7 and fires the packet
at all of them, so the ASUS received the LG's service-channel write on every switch.
`Test-LgBlastRadius` existed solely to compensate, by refusing whenever an
unrecognised panel was attached.

NVAPI can address a single output. Doing so bought, in one change:

- **done** -- removed the `0xF4` spray and `Test-LgBlastRadius` with it. The guard
  became "refuse unless the LG is positively identified", which is stronger, and it
  stopped punishing a third monitor for being attached
- **done** -- deleted a 16MB GPL-3.0 binary, its pinned download and SHA check, and
  the install-time network dependency
- **done** -- removed the LG half's desktop dependency, which is what makes
  pre-login possible
- **not yet** -- collapsing the dual code path, which needs the ASUS on the same
  transport

## Function ids

Corroborated by two independent sources -- [SimpleKVM](https://github.com/fiddyschmitt/SimpleKVM)
(MIT) and [lg-input-switch](https://github.com/meer-cha/lg-input-switch) (GPL-3.0):

```
NvAPI_Initialize                         0x0150E828
NvAPI_EnumPhysicalGPUs                   0xE5AC921F
NvAPI_I2CWrite                           0xE812EB07
```

Single-sourced (SimpleKVM), but **corroborated by result** -- `nvapi-probe.ps1` used
all three and returned EDID values matching those measured independently through the
Windows PnP path:

```
NvAPI_GPU_GetConnectedDisplayIds         0x0078DBA2
NvAPI_GPU_GetEDID                        0x37D32E69
NvAPI_SYS_GetGpuAndOutputIdFromDisplayId 0x112BA1A5
```

Used by lg-input-switch, not needed by an aimed design:

```
NvAPI_GPU_GetConnectedOutputs            0x1730BFC9
```

Resolution is via `nvapi_QueryInterface` exported from `nvapi64.dll` (fall back to
`nvapi64_QueryInterface`). Requires a 64-bit process.

## Struct traps

Struct version is `sizeof(struct) | (version << 16)`. Get the layout wrong and the
encoded size is wrong and NvAPI rejects the call with an unhelpful error. Both of
these were bugs SimpleKVM had to fix, per its own comments:

- **`NV_EDID` (v3) needs trailing `edidId` and `offset` fields.** Correct size 272,
  version `0x00030110`. Verified by the probe.
- **`NV_I2C_INFO` (v3) needs a trailing `bIsPortIdSet` field.** Untested here.
- `NV_GPU_DISPLAYIDS` (v3): size 16, version `0x00030010`. Verified by the probe.

**The output-id trap, which would cost hours:** `NvAPI_GPU_GetEDID` and
`NvAPI_I2CWrite` take the **legacy single-bit output id**, not the `displayId` that
`GetConnectedDisplayIds` returns. Convert with
`NvAPI_SYS_GetGpuAndOutputIdFromDisplayId`. Measured on this machine:

```
ASUS PG42UQ    displayId=0x80061083   outputId=0x00000100   HDMI
LG 45GX950A    displayId=0x80061082   outputId=0x00000200   DisplayPort
```

`NV_GPU_DISPLAYIDS.flags`: bit 6 (`0x40`) isConnected, bit 2 (`0x04`) isActive.
**Use isConnected. Do not gate anything on isActive** -- it read `False` for both
panels at 15:51 and `True` for both at 16:13 *in the same interactive session*, with
no deliberate change between. It therefore varies over time rather than by execution
context, and what it tracks is not established. `isConnected` was stable across all
five runs and all three contexts.

## Packet framing -- the two sources disagree

Same bytes on the wire, different NVAPI call shape. If one fails, try the other:

```
lg-input-switch   whole packet in pbData;  pbI2cRegAddress = NULL, regAddrSize = 0
SimpleKVM         source byte in pbI2cRegAddress (regAddrSize = 1), rest in pbData
                  -- "matching NVIDIA's I2C sample ... the same bytes as the AMD path"
```

Both projects report this working, so this is a fork in the road rather than a known
right answer. Common to both: `i2cDevAddress = 0x6E` (slave `0x37` shifted for a
write), `bIsDDCPort = true`, `i2cSpeed = 0xFFFF` (deprecated, must be this),
`i2cSpeedKhz = 0`.

Message construction (`DdcCiMessage.BuildSetVcp`): `[srcAddr, 0x84, 0x03, vcpCode,
valueMsb, valueLsb, checksum]`, checksum = `0x6E` XOR every preceding byte. The
source address byte is what selects LG's sidechannel: `0x50` instead of `0x51`.

Reference packets, independently reproduced by both projects and matching this
repo's own notes:

```
LG -> DisplayPort   50 84 03 F4 00 D0 9D
LG -> USB-C         50 84 03 F4 00 D1 9C
```

## Measured, 2026-08-30, this machine (RTX 4090, driver 32.0.16.1062)

`windows/nvapi-probe.ps1` -- enumeration and EDID only, no writes -- in three
contexts:

| Context | sessionId | user32 sees | NVAPI sees | EDIDs correct |
|---|---|---|---|---|
| interactive user | 1 | 2 | 2 | yes |
| SYSTEM | 0 | **1 (phantom)** | 2 | yes |
| S4U user, unelevated | 0 | **1 (phantom)** | 2 | yes |
| at-startup task after cold boot, both principals | 0 | **1 (phantom)** | 2 | yes |

The boot row is three samples per principal, at uptime 38s / 72s / 132s, all six
identical and correct -- so an at-startup trigger needs no delay and no retry loop.
Caveat on that run: the login raced the wrapper's startup, so the earliest sample
landed a few seconds *after* the shell came up. It proves an at-startup session-0
task works from 38s onward; it does not isolate "nobody has ever logged on".

Three conclusions:

1. **NVAPI enumerates and identifies displays with no desktop.** This is the
   precondition for pre-login switching, and it removes the need for the
   token-duplication / Winlogon-desktop relay that was the fallback design.
2. **Session 0 reports one phantom monitor through user32, not zero.** "No desktop"
   means *wrong* monitors reported, not none. This is why `ddc-hi` in a service logs
   "Did not detect any DDC-compatible displays" rather than finding nothing --
   see haimgel/display-switch issue #17.
3. **NVAPI must therefore be the sole identity source, never correlated against the
   Windows display list.** SimpleKVM's `I2CTransportManager.BuildDisplayMap` matches
   vendor displays against user32-enumerated displays; that structure would map
   nothing in session 0. Do not lift it.

Also worth knowing if the matching logic is ever lifted from SimpleKVM: its layer-1
serial match is dead code -- the predicate requires `EdidSerial != 0 && EdidSerial ==
GetEdidSerial(winDisplay)` and `GetEdidSerial` is a stub returning `0` -- so it
always falls through to product+connector, then to product-only *in enumeration
order*. Order-based fallback is exactly what this repo's conventions forbid.

## The write path, as built

`NvDdc` in `windows/switch-displays.ps1`. Three decisions worth keeping:

**`NV_I2C_INFO_V3` must marshal to 64 bytes on x64**, i.e. version `0x00030040`.
`Init()` computes it and refuses with an explicit message rather than handing NvAPI
a wrong size and reading back an obscure error code. Confirmed 64 on this machine.

**The `0x50` source byte is unrepresentable outside one function.** There is no
generic `WriteVcp(source, vcp, value)`. The only entry point is
`WriteLgInput(target, value)`, which hard-codes source `0x50` / VCP `0xF4` and
throws unless `target.EdidVendor == 0x1E6D`. So "never aim the LG sidechannel at a
non-LG panel" holds by construction rather than by caller discipline. Both branches
of that gate were exercised against a target carrying a null GPU handle and a zero
display mask, which cannot reach a real monitor: an ASUS-vendor target was refused,
a GSM-vendor target passed the gate and reached `NvAPI_I2CWrite`, which returned
`-1` for the invalid handle rather than crashing -- so the delegate marshalling and
struct layout are exercised end to end.

**Framing: lg-input-switch's.** Whole packet in `pbData`, `pbI2cRegAddress = NULL`,
`regAddrSize = 0`. The tie above is broken by evidence rather than preference:
lg-input-switch is what demonstrably drove *this* panel. There is deliberately no
flag to select SimpleKVM's shape -- if this one ever fails, change the function and
re-test.

## Proven on hardware, 2026-08-30

**`NvAPI_I2CWrite` drives this panel, aimed, in both directions -- confirmed
visually.** `-Only lg` to USB-C and back to DisplayPort, then the ASUS both ways as a
regression check on the shared code. The pull-back cases were run with the panel
**displaying the Mac**, so the aimed write works from an inactive link -- the case the
whole design depends on, and one that had only ever been established for
`lg-input-switch`.

lg-input-switch's framing is therefore the correct one for this panel, and
SimpleKVM's alternative below is recorded for the next hardware, not for this one.

**The ASUS answers on the same transport at standard source `0x51`, VCP `0x60`** --
verified visually the same day, both directions, including its pull-back from an
inactive link over HDMI. That collapsed the dual code path: the `dxva2`/`user32`
bindings and the PnP-interface-path matcher are deleted, both panels resolve by EDID
through NVAPI, and `windows/switch-displays.ps1` now touches no desktop API at all.
Why no vendor-neutral fallback was kept:
`../docs/decisions/001-nvapi-as-the-only-windows-transport.md`.

## Still unproven

- Whether the write works from session 0. Enumeration does there; writing has only
  been done from an interactive session. This is the remaining gate on a pre-login
  tier -- and the one thing phase 1 could not answer, because phase 1 sent no writes.
- Whether this holds at the actual logon screen, before any user has logged in. See
  the caveat on the boot row above.

## Licence

SimpleKVM is MIT, so the binding approach is liftable with attribution -- which is
what was done. lg-input-switch is GPL-3.0: invoking it as a separate binary was
fine, but forking or vendoring it would have made this repo GPL. That is why the
transport was built on SimpleKVM's approach rather than by patching lg-input-switch
to aim. Nothing from lg-input-switch is copied; what it contributed is
corroboration of three function ids and the packet framing choice, both facts
rather than code. It is no longer a dependency.

Related: [[autologin-tier]] (rejected). The implementation lives in
`windows/switch-displays.ps1` (`NvDdc`) and `windows/nvapi-probe.ps1`.
