# Making an unfamiliar monitor work

The question this started from: `$KNOWN_MONITORS` had two entries, both on this
desk, and anyone else who uses this would have neither.

Most of it is now built — see **Built** below. What remains is the capabilities read
and the advanced escape hatch.

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

## Built

Items 1-3 shipped 2026-08-30. What they became is documented in
`windows/README.md` under "Monitors nobody has met", and the rule they answer to is
AGENTS.md hard rule 1b:

- The panel's own name out of the EDID (`0xFC` descriptor), so no name table ships.
- `$DIALECTS`, keyed by EDID **vendor**, replacing the per-model `$KNOWN_MONITORS`.
- Standard DDC/CI first for every panel; a dialect offered only after the monitor
  test reports that nothing happened.
- A three-way test outcome, because "did not come back" (wrong `self`) and "nothing
  happened" (wrong channel) have different fixes.
- Blind MCCS walking as an explicit last resort: standard only, one value at a time,
  cost stated, refused when it would take the last display.
- User-named inputs, persisted value-first as `display.<label>.input.<value>`.

## Still unbuilt

### The capabilities read

DDC/CI opcode `0xF3` asks for a capabilities string; the `0xE3` reply is ASCII,
usually containing a `vcp(...)` section that lists supported codes and, for discrete
features like `0x60`, the permitted values — `60(11 12 0F)`. That would turn eight
MCCS guesses into three real ones, and would make blind walking short enough to stop
being a last resort.

Deliberately last, and still not done:

- **It cannot help the hard case.** A standard capabilities string will never mention
  `0xF4` or its values. The panel that motivated this project is exactly the one it
  cannot describe.
- **These panels lie on reads.** Capabilities is a different opcode from a feature
  read, so hard rule 2 does not strictly forbid it — but on a monitor that returns
  `0` for every feature read, assuming its capabilities reply is honest is unearned.
- **It is the most work.** An I2C read path, the fragmented offset-addressed
  multi-packet protocol, and a parser — none of which exist. Only `NvAPI_I2CWrite`
  is bound.
- **It only shortens a list**, and the list is now walked with the user watching
  either way.

Build it when a third-party standard-DDC monitor is actually in the room to test
against. Until then it is speculative work resting on an unreliable input.

### The advanced escape hatch

For a panel that answers neither standard DDC nor any known dialect. **One** specific
address and **one** specific value, typed by the user, behind a strong disclaimer.
Never a sweep across a range of either — user-ratified, and the reason hard rule 1
exists. Today that case ends with "nothing known reaches this panel"; the hatch is
what would come after that sentence. Tracked in `TODO.md`.

## Related

- [[nvapi-transport]] — why there is one transport, and the 64-byte struct.
