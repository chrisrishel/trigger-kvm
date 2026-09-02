# 004 -- The Intel-Mac DDC route: proven, deliberately not built

Date: 2026-09-01
Status: accepted -- capability proven, transport declined for now

## Context

The macOS switcher reaches monitors through `m1ddc`, which uses `IOAVService`, an
interface Intel Macs do not have. Intel Macs expose DDC/CI through the
framebuffer's I2C interface instead. Whether that route reaches THESE panels
through THIS desk's cabling was measured on 2026-09-01, rather than assumed.

**It does. Completely.** Every operation the Apple Silicon and Windows switchers
perform was performed from an Intel MacBook Pro: both panels, both channels
(standard `0x60` and the LG's service `0xF4` on source `0x50`), both directions,
each confirmed by a person looking at the screen. The full readings, including
what the APIs lie about, are in `docs/measurements.md` under "Intel DDC route".

So this is not a question of feasibility. It is a question of whether the desk
wants a second transport.

## Decision

**Do not build it now.** Keep the measuring instrument that proved it, and keep
this record so the work can be resumed mechanically rather than re-derived.

### Why not

The reason is NOT propagation cost, and it is worth being precise because the
obvious framing is wrong. Intel support would not be a third *platform*: it is
the same macOS implementation with an arch switch inside one function. Same
`specs/`, same `SPEC-REVISION`, same conformance check, same suite, same
`HANDOFF.md`, same walkthrough and menus. A spec change would still fan out to
two implementations, not three.

The real cost is **verification**. It would put code paths in the macOS tree that
can only be exercised on a machine that is not a daily driver and has to be
deliberately cabled to two monitors to test. This repo's standard is that
completion claims are evidence-bound, so every future macOS change would force a
choice between shipping a knowingly unverified branch and staging hardware. That
is a recurring tax, paid forever, for a machine nobody works on.

Against that: the walkthrough, menus and flows are still moving. Adding a second
transport now would freeze an interface that is still being explored.

### Revisit when

An Intel Mac becomes a machine someone actually works on at this desk. That is
the trigger; nothing else is. If it fires, this record plus
`macos/intel-ddc-probe.c` should make the build mechanical.

## What the route needs, if it is built

### The seams -- three places, with line numbers

| Where | What changes |
|---|---|
| `macos/lib/display.sh:163` | The ONLY arch-dependent line: `"$M1DDC" display "$_uuid" set "$_sub" "$_value"`. Becomes `"$DDC_TOOL"`, chosen once by `uname -m`. |
| `macos/install.sh:123` | The arch preflight refusing x86_64. Becomes conditional: arm64 requires `m1ddc`; x86_64 requires the shipped binary and needs **no Homebrew at all**. |
| `macos/tests/lib.sh:211` | `M1DDC="$FAKE_DIR/m1ddc"`, the harness seam. Renaming it is a reference sweep across five test files that name `M1DDC`. |

Everything else is already arch-neutral: `display_switch`, `display_resolve`,
`ddc_send`'s method→channel selection, its GSM refusal, its retry loop, its
"sent, not switched" contract, the config, the walkthrough, launchd, locking, and
`event-watch` (measured working on Intel).

### Keep `ddc_send` as the one door

`ddc_send` is already the single gate. It stays the single gate: the arch picks
the *tool*, not the *policy*. So the Intel binary must present `m1ddc`'s CLI --
`display <uuid> set input|input-alt <value>` -- and then line 163 changes by one
variable and nothing else moves.

Inside the binary: `CGDisplayGetDisplayIDFromUUID` → `CGDisplayVendorNumber` /
`CGDisplayModelNumber` → match those against each framebuffer's
`IODisplayCreateInfoDictionary`. This deliberately avoids the deprecated
`CGDisplayIOServicePort`, and it must re-resolve on every invocation (see the
gMux trap below).

### The wire facts

Slave address `0x6E`; the source byte is payload byte 0; checksum is `0x6E` XOR
every preceding byte. Both packets below were sent over `IOI2CSendRequest` and
moved the panels, and both match `displays.toml` byte for byte:

```
ASUS  standard  -> DisplayPort   51 84 03 60 00 0F D7
ASUS  standard  -> HDMI 2        51 84 03 60 00 12 CA
LG    service   -> DisplayPort   50 84 03 F4 00 D0 9D
LG    service   -> USB-C         50 84 03 F4 00 D1 9C
```

The `IOI2CRequest` fields that worked, for a write:

```c
req.sendAddress          = 0x6E;
req.sendTransactionType  = kIOI2CSimpleTransactionType;
req.sendBuffer           = (vm_address_t)(uintptr_t)send;
req.sendBytes            = sizeof send;
req.replyTransactionType = kIOI2CNoTransactionType;   // a write takes no reply
req.replyBytes           = 0;
```

Reads additionally need `replyAddress = 0x6F`, `replySubAddress = 0x51`,
`minReplyDelay = 30 * kMillisecondScale`, and
`replyTransactionType = kIOI2CDDCciReplyTransactionType` where the bus offers it.

**`kIOI2CCombinedTransactionType` is 3, not 4** -- `kIOI2CDisplayPortNativeTransactionType`
is 4. Decoding the transaction-type bitmask with the wrong constant makes a bus
look like it lacks a capability it has.

### The traps, all measured

- **Enumeration proves nothing.** `IODisplayCreateInfoDictionary` returns a
  NON-NULL but empty dictionary for a vacant framebuffer, and a vacant framebuffer
  still advertises `0x1F` (simple + DDCci + combined). Require an actual EDID.
- **`result == 0` proves nothing.** The internal panel returned
  `IOI2CSendRequest=0x0`, `result=0x0` and pure garbage. Only the `6E 88` reply
  framing distinguishes an answer from a non-answer.
- **The gMux migrates displays between framebuffers on hotplug.** With nothing
  attached the built-in panel sat on `AppleIntelFramebuffer`; once an external
  arrived it moved to the AMD framebuffer. Never cache a framebuffer handle;
  resolve by EDID at send time.
- **Read VALUES still lie**, exactly as hard rule 2 says. The LG returned `0x0F`
  on every input because its standard `0x60` is stubbed. Do not build
  verify-then-retry.

### The door-counting conflict, which must be resolved deliberately

`tests/conventions.tests.sh` asserts `0x50` appears in exactly one non-comment
line across `macos/*.c`. That line is today in `intel-ddc-probe.c`. **Shipping a
second C file that emits `0x50` will fail that check, correctly.** So a real tool
either removes the instrument's `--set-lg-input`, or is grown out of the
instrument itself. Decide this before writing the file, not after the test goes
red.

Hard rule 5 was amended in this same commit to permit exactly this shape: a
measuring instrument may carry its own emitter provided it is never installed,
not built by default, gated the same way, and covered by the same self-tested
scan.

### Still unknown -- would need measuring first

- **The 13" 2019 MacBook Pro drives externals from the Intel GPU**, a different
  framebuffer driver. Nothing here transfers to it. A warning sign from these
  readings: the `AppleIntelFramebuffer` advertised `0x13` with **no DDCci bit**
  and returned `kIOReturnUnsupported`. Scope any claim to *Intel Macs with
  discrete AMD graphics*, measured on `MacBookPro16,1`.
- **No-session operation.** The boot tier was measured on arm64 (LaunchDaemon,
  uid 501, no session). The Intel path uses CoreGraphics for UUID resolution and
  was never run without a session. Re-measure rather than generalise.
- The LG's `hdmi1` (`0x90`) and `hdmi2` (`0x91`) sidechannel values remain
  unexercised, and are deliberately absent from the instrument's allowlist.

### Cheap safety win available

`m1ddc` has no vendor gate of its own, so on arm64 `ddc_send`'s check is the only
thing between the service channel and a non-LG panel. The Intel binary carries
its own refusal at the transport, giving two independent gates. It should also
refuse any `input-alt` value outside the four `displays.toml` documents --
stricter than what arm64 has today, and nearly free.

## The code

`macos/intel-ddc-probe.c` is kept in the tree as the executable half of this
record. It is a measuring instrument, not a component: excluded from `make all`,
never installed, and its two emitters are the ones proven above. A rebuild starts
by moving those functions into a new `main`, not by rediscovering them.

If it is ever removed, it is recoverable at
`git show cc8b2d5:macos/intel-ddc-probe.c`.

## Consequences

- `README.md` keeps saying Apple Silicon, because that is what is supported. The
  route existing is not the same as the product supporting it.
- `macos/HANDOFF.md`'s entry is discharged and deleted; this record replaces it.
- `tests/conventions.tests.sh` gained a C-side scan of the service channel, which
  it needed regardless: it had been asserting "one door" while covering only the
  shell half of the tree.
