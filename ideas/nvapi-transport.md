# Idea: an NVAPI transport to replace lg-input-switch

**Status:** enumeration half proven on this machine 2026-08-30 (see Measured, below).
Write half unbuilt and untested. This note is the working reference for building it.

## Why

The Windows LG path currently shells out to `lg-input-switch.exe`, which cannot be
aimed: it loops every connected output mask against ports 0-7 and fires the packet
at all of them, so the ASUS receives the LG's service-channel write on every switch.
`Test-LgBlastRadius` exists solely to compensate, by refusing whenever an
unrecognised panel is attached.

NVAPI can address a single output. Doing so would, in one change:

- remove the `0xF4` spray, and with it hard rule 5 and `Test-LgBlastRadius` in its
  current form (the guard simplifies to "refuse unless the LG was positively
  identified" -- stronger, and it stops punishing a third monitor being attached)
- delete a 16MB GPL-3.0 binary, its pinned download and SHA check, and the
  install-time network dependency
- collapse the dual code path if the ASUS moves onto the same transport
- remove the last desktop dependency, which is what makes pre-login possible

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

## Still unproven

- **`NvAPI_I2CWrite` has never been called from any context here.** Enumeration
  working does not imply writing works, in session 0 or anywhere else. Test the
  write in a normal interactive session first, visually confirmed, before testing
  it without a desktop.
- Whether this holds at the actual logon screen, before any user has logged in.
  Both privileged runs above happened while a user was logged on; only session 0
  was empty of a desktop, not the machine of a session.
- Whether the ASUS can be driven over the same transport at source `0x51`
  (would collapse the dual code path).

## Licence

SimpleKVM is MIT, so the binding approach is liftable with attribution.
lg-input-switch is GPL-3.0 -- fine to invoke as a separate binary, as today, but
forking or vendoring it would make this repo GPL. That is a reason to build on
SimpleKVM's approach rather than patching lg-input-switch to aim.

Related: [[autologin-tier]] (rejected), `.context/PLAN.md` phases 1-4.
