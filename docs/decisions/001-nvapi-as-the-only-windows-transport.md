# 001 -- NVAPI as the only Windows transport

**Date:** 2026-08-30
**Status:** accepted

## Context

Phase 2b moved the ASUS from `dxva2.dll` (`SetVCPFeature`) onto the same aimed NVAPI
I2C write the LG uses, and deleted the `dxva2`/`user32` code. That raises a fair
question: NVAPI is NVIDIA-only, so does deleting the vendor-neutral path give up the
ability to run on an AMD or Intel GPU, and should a fallback be kept?

Three facts settle it.

**The LG half was never vendor-neutral, and cannot be.** Its input control lives on
LG's manufacturer sidechannel at I2C source `0x50`. The Windows DDC/CI stack
hardcodes source `0x51` and cannot express `0x50` at all, so `dxva2` cannot reach it
by any arrangement of arguments. Raw I2C injection is the only route, and on this
hardware that means NVAPI.

**So the repo was already NVIDIA-only, before this change and before phase 2a.**
`windows/README.md` has stated "NVIDIA GPU" as a hard requirement since well before
this work; the previous LG path, `lg-input-switch.exe`, is itself an NVAPI program.
Moving the ASUS onto NVAPI therefore removes **no** hardware compatibility that the
project had. It relocates code that was already unreachable on a non-NVIDIA machine,
because its sibling would have failed there anyway.

**Keeping `dxva2` would cost something real.** It is desktop-bound: session 0 has no
`HMONITOR`, and worse, `user32` there reports a *phantom* monitor rather than none,
so it fails by mis-resolving rather than by erroring. Keeping the ASUS on it would
leave a desktop dependency in the switcher and forfeit the main prize of phase 1's
result -- that a pre-login tier needs no relay. A retained-but-unused fallback would
also rot: nothing would exercise it, and this project's safety rests on things being
verified rather than assumed.

## Decision

NVAPI is the single Windows transport. The `dxva2` path is deleted, not retained as
a dormant fallback.

## Consequences

- The switcher has no desktop dependency, which is what makes a pre-login tier cheap.
- One transport, one identity mechanism, one write path. `Switch-Asus` and
  `Switch-Lg` differ only in which write they pass to a shared `Invoke-Switch`.
- A non-NVIDIA GPU is unsupported -- unchanged from before, and stated in
  `windows/README.md`.
- The deleted `dxva2` implementation remains in git history: the commit that removed
  it is `70e5ed4` ("one NVAPI transport for both panels, drop dxva2"), so the last
  working, verified copy is its parent, `70e5ed4^`.

## What would reopen this

Generalising the project to other people's hardware (phase 3). For someone whose
monitors all speak **standard** DDC/CI, a `dxva2` transport is genuinely
vendor-neutral and would let the project run on any GPU. That is worth building when
generalisation is actually being done -- and the right shape then is a transport
*selected* for the machine and the panel, discovered at install time, not a dormant
branch carried in the switcher meanwhile.

Note the asymmetry that survives any such work: a standard-DDC panel can be driven
anywhere, but **an LG whose input lives on `0x50` still needs raw I2C**, so any
vendor-neutral tier is limited to standard-DDC monitors. It would not help this
particular desk.
