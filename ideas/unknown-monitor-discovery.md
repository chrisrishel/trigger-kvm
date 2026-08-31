# Making an unfamiliar monitor work

Exploratory. Nothing here is built. The question: `$KNOWN_MONITORS` has two entries,
both on this desk, and anyone else who uses this will have neither.

## The constraint everything else follows from

**We cannot verify a switch.** Hard rule 3, and it is not caution — both panels here
have produced false negatives (AGENTS.md hard rule 2). So there is no scheme in
which the tool works out the right value on its own. Every route ends in *write a
value, ask the human what appeared*.

That settles what each idea below can be. Nothing is a detector. The only things
worth building are ones that **make the human loop shorter or safer**, and none of
them may become load-bearing, because an unreliable input that only shortens a list
is safe by construction and one that gates a decision is not.

## What is knowable for free, today

- **EDID vendor and product**, from NVAPI, already read for identity.
  `1E6D` = GSM = LG Electronics. So "is this an LG" is answerable, reliably, at zero
  cost, before anything is written.
- Nothing else. There is no I2C read path in the repo at all: the only call is
  `NvAPI_I2CWrite` (`0xE812EB07`).

## The shape

### 1. Key the table by MANUFACTURER, not by model

This is the change that makes the database scale, and it is small.

Today `$KNOWN_MONITORS` is keyed `1E6D:9E9D` — one LG, on a panel whose product id
is *per input* (`0x9e9d` DP / `0x9e9f` USB-C), so the key is nearly per-cable. One
entry covers one desk.

The transport layer already got this right: `NvDdc.WriteLgInput` gates on
`EDID_VENDOR_GSM = 0x1E6D`, the vendor alone. The installer should match it.

Split the table in two, because the halves have different lifetimes:

- **Manufacturer dialect** — I2C source, VCP code, and the documented value set for
  that maker's sidechannel. Small, slow-growing, contributable, and the only part
  worth shipping. LG's DDC2AB entry (`0x50` / `0xF4` / `D0 D1 90 91`) is the whole
  table today.
- **Per-model input labels** — does not scale, and does not need to. See §3.

`display.<label>.method` in the config is already the right abstraction for a
dialect. It just needs to be chosen per *vendor* rather than per model.

### 2. Escalate, and never probe a sidechannel

The ladder, for a panel nobody has met:

1. **Standard DDC first.** Source `0x51`, VCP `0x60`, MCCS values. This is what
   most monitors answer to and it is the only place discovery is permitted at all
   (ratified constraint 11).
2. **Walk candidates one at a time** with the existing probe shape: switch away,
   hold, come back **automatically**, then ask. The question always arrives on a
   panel that has already returned. Never a sweep, never a range.
3. **If nothing on `0x60` does anything**, and the vendor is in the dialect table,
   *offer the documented values for that maker* — "this is an LG, and LG panels of
   this era put input switching on a manufacturer channel; I know these values".
   **Offer, not probe.** The distinction is the whole of hard rule 1: a bricked-LG
   report exists, and it came from experimental writes to a manufacturer channel.
4. **If the vendor is unknown and `0x60` does nothing**, stop and say so plainly.
   Point at the advanced escape hatch — one specific address, one specific value,
   typed by the user, behind a disclaimer. Never a search.

Step 3 is where an earlier sketch said "try the other channel if 0x60 fails". The
correction is small and load-bearing: values for a sidechannel come from the
dialect table or from the user's own fingers, never from us trying things.

### 3. Let the user name what they find

The reason per-model labels do not need to scale: if someone tries `0x12` and says
"that is my Mac", we now know that label **on their desk**, which is better than
anything shippable — a shipped label says "HDMI 2", theirs says "Mac".

So the discovery loop should ask *what did you see* with three answers — nothing /
No Signal, this PC, something else — and let them name the third. Write the names
into their config. The shipped `$MCCS_INPUTS` names become a starting suggestion
rather than an answer.

This also disposes of the "what if there are no labels" worry: unlabelled is the
normal case, and the user is a better source than the tool.

### 4. The capabilities read — worth doing, worth doing LAST

DDC/CI opcode `0xF3` asks for a capabilities string; the `0xE3` reply is ASCII,
usually containing a `vcp(...)` section that lists supported codes and, for discrete
features like `0x60`, the permitted values — `60(11 12 0F)`. That turns eight MCCS
guesses into three real ones.

Why last, despite being the most interesting:

- **It cannot help the hard case.** A standard capabilities string will never
  mention `0xF4` or its values. The panel that motivated this whole project is
  exactly the one this cannot describe. It helps monitors that were already easy.
- **These panels lie on reads.** Capabilities is a different opcode from a feature
  read, so the rule does not strictly forbid it — but on a monitor that returns `0`
  for every feature read, assuming its capabilities reply is honest is unearned.
  Untested, and testable only on hardware we have.
- **It is the most work.** An I2C read path, the fragmented offset-addressed
  multi-packet protocol, and a parser — none of which exist.
- **It only shortens a list**, and a shorter list of things the human still has to
  confirm one at a time is a real but bounded win.

Build it when a third-party standard-DDC monitor is actually in the room to test
against. Until then it is speculative work on an unreliable input.

## Suggested order

1. Rekey the dialect table to vendor. Small; aligns the installer with the gate the
   transport already enforces.
2. Naming during discovery, written to the user's config. Removes the per-model
   label problem entirely.
3. The one-at-a-time discovery loop on `0x60`. Constraint 11 already permits it;
   `Test-DisplayInput` is already the right probe shape.
4. Capabilities read, if and when there is unfamiliar hardware to try it on.

Hard rule 4 applies throughout: one monitor at a time, never the last display.

## Related

- [[nvapi-transport]] — why there is one transport, and the 64-byte struct.
- The deferred advanced escape hatch (single address, single value, typed by the
  user, strong disclaimer) is step 4 of the ladder and still unwritten.
