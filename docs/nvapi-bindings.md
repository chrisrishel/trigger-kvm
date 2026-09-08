# NVAPI bindings used by the Windows switcher

Reference for the ids, struct versions and framing in `windows/trigger-kvm.ps1`
(`NvDdc`) and `windows/nvapi-probe.ps1`. **Never hand-write an NVAPI binding
from memory**: dispatch uses magic function ids and size-encoded struct
versions, and both must come from a real source. Provenance for each is given.

## Function ids

Corroborated by two independent sources,
[SimpleKVM](https://github.com/fiddyschmitt/SimpleKVM) (MIT) and
[lg-input-switch](https://github.com/meer-cha/lg-input-switch) (GPL-3.0):

```
NvAPI_Initialize                         0x0150E828
NvAPI_EnumPhysicalGPUs                   0xE5AC921F
NvAPI_I2CWrite                           0xE812EB07
```

Single-sourced (SimpleKVM), corroborated by result on this machine (the EDIDs
they return match the ones read through the PnP path):

```
NvAPI_GPU_GetConnectedDisplayIds         0x0078DBA2
NvAPI_GPU_GetEDID                        0x37D32E69
NvAPI_SYS_GetGpuAndOutputIdFromDisplayId 0x112BA1A5
```

Resolution is via `nvapi_QueryInterface` exported from `nvapi64.dll`. Requires a
64-bit process. The probe deliberately never resolves `NvAPI_I2CWrite`.

## Struct versions

Version is `sizeof(struct) | (version << 16)`; a wrong layout is a wrong size
and NvAPI rejects the call with an unhelpful error.

| struct | size | version | note |
|---|---|---|---|
| `NV_GPU_DISPLAYIDS` (v3) | 16 | `0x00030010` | |
| `NV_EDID` (v3) | 272 | `0x00030110` | needs trailing `edidId` and `offset` |
| `NV_I2C_INFO` (v3) | 64 on x64 | `0x00030040` | needs trailing `bIsPortIdSet`; `Init()` computes the size and refuses on a mismatch |

All three accepted unchanged across NVIDIA driver 610.62 -> 616.64
(`docs/measurements.md`, "Display identity").

## Ids and flags

`NvAPI_GPU_GetEDID` and `NvAPI_I2CWrite` take the **legacy single-bit output
id**, not the `displayId` that `GetConnectedDisplayIds` returns; convert with
`NvAPI_SYS_GetGpuAndOutputIdFromDisplayId`. Both ids survived cold reboots, a
cable move off the card and back, and a driver update on this machine, while
GDI names did not. `outputId` is a mask scoped to one GPU; `displayId` is
documented as system-unique.

`NV_GPU_DISPLAYIDS.flags`: bit 6 (`0x40`) `isConnected`, bit 2 (`0x04`)
`isActive`. **Gate on `isConnected` only.** `isActive` read `False` then `True`
for both panels in one session with nothing changed; what it tracks is not
established.

## Framing

`i2cDevAddress = 0x6E`, `bIsDDCPort = true`, `i2cSpeed = 0xFFFF` (deprecated,
must be this), `i2cSpeedKhz = 0`. The whole DDC/CI packet goes in `pbData` with
`pbI2cRegAddress = NULL`, `regAddrSize = 0` (lg-input-switch's shape, the one
measured to drive this LG). SimpleKVM instead puts the source byte in
`pbI2cRegAddress` with `regAddrSize = 1`; recorded for the next hardware, not
this one, and there is deliberately no flag to select it.

Packet: `[source, 0x84, 0x03, vcp, valueMsb, valueLsb, checksum]`, checksum
`0x6E` XOR every preceding byte. The source byte selects LG's sidechannel:
`0x50` instead of `0x51`. Only `NvDdc.WriteLgInput` can produce `0x50`.

## Session 0

NVAPI enumerates and identifies both panels with no desktop (interactive,
SYSTEM, unelevated S4U, at-startup after a cold boot) and writes from session 0;
`user32` in the same contexts reports one phantom monitor, so NVAPI is the only
identity source the boot tier may use and is never correlated against the
Windows display list. SimpleKVM's `BuildDisplayMap` does that correlation and
must not be lifted.

## Licence

SimpleKVM is MIT and its binding approach was lifted with attribution
(`THIRD-PARTY-NOTICES.md`). lg-input-switch is GPL-3.0; nothing from it is
copied, and it is no longer a dependency.
