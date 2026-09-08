# Telling two identical monitors apart

**Status:** designed, not built. The measurement it waited on has been taken
(2026-09-05): NVAPI's `displayId` and `outputId` are port identities, stable
across cold reboots, a cable move and a driver update. Nobody here owns a pair
of identical panels, so the two-panel case itself is reasoning, not measurement.

## What happens today

Identity is the EDID vendor:product pair and two identical panels are one
identity. Control fails closed (the switcher refuses to resolve an id matching
more than one output), and revision 13 made that visible: `list` shows both,
`configure` refuses to manage the identity, `status` names it
(`specs/configure.md` 6.4, `specs/status.md` 5). What remains is that neither
panel can be configured.

## The design: the port, as a tiebreak, consulted only on ambiguity

The same shape as the trigger side's `@where` (`specs/detector.md` 4.1):

```
display.left.vendor  = 0x10AC
display.left.product = 0x41A2
display.left.output  = 0x80061082     # tiebreak; consulted ONLY on ambiguity
```

| outputs matching vendor:product | outcome |
|---|---|
| exactly one | match it; `output` is not consulted, so a cable move costs nothing |
| none | refuse, as today |
| several, one at `output` | the tiebreak decides |
| several, none at `output` | ambiguous: refuse, and say so in `status` |

On Windows the value is `displayId` (system-unique, unlike `outputId`, which is
a per-GPU mask; a two-card collision would fall to the last row and refuse). The
key is `output`; the value is each platform's, as with `transport`. macOS would
need to choose its stable per-port handle; the CoreGraphics UUID is not one.

**Why it does not break the "never by index" rule.** The tiebreak is reached
only when vendor:product already matched more than one output, so every
candidate shares a vendor and the `0x50` channel cannot land on a foreign
panel; the transport gate is untouched. The worst outcome is the right value
reaching the wrong one of two identical panels, visible to the person looking at
both. Every use of the tiebreak is announced in `status`.

**The case where it is wrong, stated up front.** Two identical panels, A on
DP-1 and B on DP-2, config recording DP-1 as `left`. Swap the cables and `left`
names the panel on the right. Without the tiebreak that case is refused.

**The `list` union is the sharp edge.** `list` unions `nvapi` and `dxva2` rows
on the EDID key. `dxva2` has no stable per-output handle (GDI names move), so on
a twin desk it cannot aim at one of them and must not be offered for those two
(`specs/configure.md` 6.3 already permits that).

## Naming them

No automatic rule can name twins usefully; the names people want are
positional. The person is the only source of "which is on the left", and the
check flow already makes them watch a panel move. Switch one, ask which moved,
name it. The duplicate-name refusal forces the choice.

## Rejected

- **The EDID serial as a first-choice tiebreak.** The numeric field is a
  placeholder on this ASUS (`0x01010101`); descriptor `0xFF` is populated on
  both panels here but optional in the standard, and whether two units of one
  model carry different strings is unmeasured. A tiebreak untested on the only
  case it exists for does not displace one that is measured. If someone turns up
  with twins, whether their `0xFF` strings differ is the first cheap measurement.
- **The serial or the port as a primary key.** Swapping a monitor for an
  identical model would refuse where the tiebreak design keeps working.

## What it costs

One additive config key; the resolver table above; the walkthrough's answer
lookup keyed by identity on both platforms; `list -Raw` gains `displayId`. A
spec revision, then both platforms.
