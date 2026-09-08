# 001 -- NVAPI as the only Windows transport

**Date:** 2026-08-30
**Status:** superseded by [003](003-dxva2-as-a-second-windows-transport.md)
on 2026-09-01. The reasoning below still holds for the LG; what changed is that
generalising to other people's hardware, named here as the reopening condition,
happened.

## Context

The ASUS had been driven over `dxva2.dll` (`SetVCPFeature`) and the LG over an
NVAPI I2C write. Moving the ASUS onto the same aimed NVAPI write and deleting
the `dxva2` path raised the question whether a vendor-neutral fallback should be
kept.

- The LG's input control lives on I2C source `0x50`. The Windows DDC/CI stack
  hardcodes source `0x51`, so `dxva2` cannot reach it. Raw I2C is the only
  route, and on this hardware that is NVAPI.
- `dxva2` is desktop-bound: in session 0 `user32` reports a phantom monitor
  rather than none, so it fails by mis-resolving. Keeping it in the switcher
  would forfeit the pre-login tier.
- A retained-but-unused fallback rots; nothing would exercise it.

## Decision

NVAPI is the single Windows transport; the `dxva2` path is deleted rather than
kept dormant.

## Consequences

- The switcher had no desktop dependency, which is what makes a pre-login tier
  cheap.
- A non-NVIDIA GPU was unsupported.
- The deleted implementation is at `70e5ed4^`.

## What reopened it

Generalising to other people's hardware: for monitors that all speak standard
DDC/CI, a `dxva2` transport is vendor-neutral. The shape asked for here, a
transport *selected* per panel at install time rather than a dormant branch, is
what 003 built. The asymmetry survives: an LG whose input lives on `0x50` still
needs raw I2C.
