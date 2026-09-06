# Telling two identical monitors apart

**Status:** exploratory, nothing built -- but **the measurement it was blocked on
has been taken (2026-09-05) and the design survives it**: `OutputId` is a port
identity, not a per-boot handle. See "The measurement it was waiting on" below,
which also settles which NVAPI field to record. The sibling note for the same
problem on the trigger side is `telling-two-identical-devices-apart.md`, whose
design is settled and shipped (revision 12); much of the reasoning here is that
argument re-checked against displays rather than re-derived.

The question this started from: what happens if someone attaches two identical
monitors? Nobody here owns a pair, so every claim about the two-panel case is
reasoning, not measurement, and is marked as such.

## What happens today

Identity is the EDID vendor:product pair and nothing else, and two identical
panels are one identity. That broke at three layers; **revision 13 closed two of
them, and is implemented on Windows only.**

**Control -- fail-closed, and correct all along.** `Resolve-Panel` refuses on
more than one match (`windows/trigger-kvm.ps1`), macOS likewise
(`macos/lib/display.sh:63-85`). Picking the first would reintroduce the
order-dependence EDID matching exists to remove, so the panel simply never
switches. Nothing here needed fixing and nothing here changed.

**Identification and discoverability -- fixed by revision 13**
(`specs/configure.md` §6.4, `specs/status.md` §5). Both platforms had a bug here
and had it *differently*, which is what made it a spec change rather than two
local fixes:

- Windows `list` unioned rows on the EDID key, so two identical panels produced
  **one row** and the second was invisible. It now carries how many attached
  panels answer to each id, the walkthrough refuses to manage an ambiguous one
  rather than taking an answer, and `status` reports one that is ambiguous now.
- macOS `wt_load_found` does not dedupe so it lists two rows, but
  `wt_answer_index` looks answers up by that same key, so both rows resolve to
  one answer record and configuring the second overwrites the first. Owed as
  revision 13; also written up in `macos/HANDOFF.md`, since a reading of their
  code is not something the machinery can tell them.

**What remains unfixed is the thing this note is about**: neither platform can
give two identical panels separate names, because the label is keyed to the
identity. Revision 13 makes that state legible and refuses it safely. It does not
make it *work*, which is what the design below would do.

## The serial is not the answer

The obvious discriminator is the EDID serial, and both platforms already carry it
and throw it away: Windows emits it as `list -Raw` field 5
(`windows/trigger-kvm.ps1:1052`) and `install.ps1:2568-2582` skips that index;
macOS `display-probe` emits it as field 5 and only `display_describe` reads it
(`macos/lib/display.sh:51`).

**Measured 2026-09-05: the ASUS reports `0x01010101`, the LG `0x00001111`.**
Details and the inference/measurement boundary are in `../docs/measurements.md`.
One of the only two panels available carries a value that has the shape of a
placeholder. A discriminator that some vendors decline to populate is not a
solution to telling twins apart -- it is a solution to telling *some* twins
apart, with the refusal path still needed underneath for the rest.

**Descriptor `0xFF` (the ASCII serial string) is a better version of the same
idea, and it is populated on both panels here** -- ASUS `AS0000000001`, LG
`LG0000000001`, measured 2026-09-05. That is a correction: this note previously
leaned on the numeric placeholder to argue the serial route was holed, and the
placeholder turns out to be a property of that one FIELD, not of the panel. It
remains deliberately not pursued, but for a narrower reason than before -- see
"Rejected while drafting", which has been rewritten rather than merely re-stated.

## THE DESIGN: the port, as a tiebreak, consulted only on ambiguity

The same shape the trigger side settled on -- identity in fields, an optional
qualifier, reached only when the identity is ambiguous, and announced whenever
it is used.

```
display.left.vendor  = 0x10AC
display.left.product = 0x41A2
display.left.output  = 0x80061082     # tiebreak; consulted ONLY on ambiguity
```

Resolution becomes:

| outputs matching vendor:product | outcome |
|---|---|
| exactly one | match it -- **`output` is not consulted, so a cable move costs nothing** |
| none | refuse, as today |
| several, one at `output` | **the tiebreak decides -- the case vendor:product alone cannot** |
| several, none at `output` | still ambiguous: refuse, as today, and say so in `status` |

On Windows the value is NVAPI's `displayId` (`windows/trigger-kvm.ps1:508`), for
the reasons under "Which field to record" below -- the key is named `output`
because that is the shared vocabulary; what a platform puts in it is its own, on
the same pattern as `transport` (revision 9). A config is machine-local and never
copied between hosts.

### Why displays are a BETTER case for a port tiebreak than triggers were

The trigger note accepted this reasoning for USB devices. Three things make it
less risky here, not more:

1. **The cable is bolted to the desk.** The staleness risk for a dongle is
   somebody moving it between ports, which happens casually. Moving a
   DisplayPort cable between two ports on the same GPU is rare and deliberate.
2. **The cost is already paid.** `where` had to be consulted in the trigger
   presence sweep -- measured at 44 ms per plug. Display resolution happens once
   per switch and `OutputId` is already in the enumerated struct. Nothing to
   measure, nothing to cache.
3. **The failure is self-revealing.** A stale trigger tiebreak fails *silently*:
   nothing fires and nothing says why. A stale display tiebreak switches the
   wrong twin, and the person is looking directly at both panels when it does.

### Why the safety rule this looks like it breaks does not apply

`../AGENTS.md`'s conventions rule is written about this exact hazard -- *"index
`1` silently becoming the other monitor would send LG service-channel writes to
the ASUS"* -- so recording a port looks like it resurrects what resolving by EDID
exists to prevent. It does not, for two independent reasons:

- **The tiebreak is only ever reached when vendor:product already matched more
  than one output**, so by construction every candidate shares a vendor. A
  mis-aim between them cannot cross a vendor boundary, and the `0x50` channel can
  never land on a foreign panel through this path.
- **The gate is at the transport regardless.** `NvDdc.WriteLgInput` refuses
  unless the target's EDID manufacturer is GSM
  (`windows/trigger-kvm.ps1:552-556`), with no source byte parameter to aim
  elsewhere. Hard rule 5 is unaffected by anything here.

So the worst outcome is the right dialect and the right value reaching the wrong
one of two identical panels: visible, harmless, immediately diagnosable. That is
a different risk class from the one the conventions rule was written about.

The two conditions the trigger note made load-bearing transfer verbatim and are
what make recording a port acceptable at all: **the tiebreak can never override a
good match** (it is stale evidence against nothing, not against better evidence),
and **every use of it is announced** in `status`, telling the reader to re-run
`configure` if they have moved cables.

**The case where it is actively wrong, stated up front.** Two identical panels, A
on DP-1 and B on DP-2, config recording DP-1 as `left`. Swap the cables and
`left` now names the panel on the right. Without the tiebreak that case would
have been ambiguous and refused. It is the same trade the trigger side accepted,
with better feedback: you can see it.

## What it costs

**The `list` union is the sharp edge, and it is independent of which
discriminator is chosen.** `list` unions nvapi and dxva2 rows on the EDID key so
one panel is not listed twice. Any key that separates twins is a key dxva2 does
not have -- it reports serial `0` (`windows/trigger-kvm.ps1:1039`) and its only
per-output handle is the `\\.\DISPLAYn` device name, **which is measured to be
unstable** (the indices swapped across a reboot, `../docs/measurements.md`,
2026-08-30). So a naive fix splits every panel into two rows on every desk today.

The way out is a rule that is correct rather than a patch, and it falls out of
the existing design: **a transport that cannot uniquely identify a panel is not
offered for that panel** (`specs/configure.md` §6.3). On a twin desk dxva2 is
simply not on the menu for those two, which is honest -- it genuinely cannot aim
at one of them.

Beyond that: one additive config key; the resolver table above; the answer lookup
keyed by EDID in the walkthrough on both platforms; and `list -Raw` gains a field
(append-only, which the format already supports -- `windows/trigger-kvm.ps1:1050`).

## The measurement it was waiting on -- taken 2026-09-05, and it holds

**Is `OutputId` a port identity or a per-boot handle?** A port identity, on this
machine. It and `displayId` both came back from a cold reboot unchanged, and both
had already survived the ASUS leaving the 4090 for the motherboard output and
returning -- an event over which the GDI name took a *third* value. Neither
tracks enumeration order either: the LG's index moved from `display[0]` to
`display[1]` between two readings while both its ids stood still. The values,
dates, and the boot-type evidence that the restart was a cold boot rather than a
fast-startup resume are in `../docs/measurements.md`.

**So the design above has a foundation.** The caution that put this section here
was right to exist -- `nvapi-transport.md` records `isActive` reading `False`
then `True` in one session with nothing changed, and *"what it tracks is not
established"* -- and what answers it is two fields on ONE machine with ONE GPU,
across three logged reboots, one cable move, and **one driver upgrade** (610.62
-> 616.64, the same day). That last one is the sharpest of the three: over the
identical event, in one boot, the GDI names moved from `\\.\DISPLAY1`/`2` to
`\\.\DISPLAY10`/`11` while both NVAPI ids did not move at all. A second card is
still unmeasured, and so is any other machine.

### Which field to record: `displayId`, not `OutputId`

Both proved stable and both are already on the enumerated row
(`windows/trigger-kvm.ps1:507-508`), so the choice is free either way and turns
on one asymmetry:

- **`OutputId` is a single-bit mask scoped to one GPU.** Two cards, and GPU0's
  first port and GPU1's first port both read `0x00000100`.
- **`displayId` is system-unique** -- NVAPI's documentation, not measured here.

Equal cost, and one of them has a collision case while the other has none. Take
the one with nothing to reason about.

**That collision would not be dangerous, which is why this is a preference and
not a safety argument.** Two identical panels on two cards at symmetric ports,
config recording `0x00000100`: the tiebreak matches BOTH candidates, so it does
not decide, and resolution falls to the last row of the table above -- refuse,
and say so in `status`. Fail-closed, exactly as today. It cannot mis-aim, and
hard rule 5's transport gate is untouched either way.

**Recording `displayId` does not put it on the write path.** `GetEDID` and
`I2CWrite` take the legacy `OutputId` (`nvapi-transport.md`, "the output-id
trap") and still would: the tiebreak SELECTS a row, and the row carries its own
`OutputId` for the write. The qualifier never aims anything.

One consequence for whoever builds it: the field `list -Raw` would gain is
`displayId`, which it does not carry today -- it exposes `outputId`
(`windows/trigger-kvm.ps1:1050-1052`), and `configure` reads that output.

**Not measurable here:** anything about the two-panel case itself. Both suites
are built so they cannot move a monitor, and hard rule 3 says a switch is
confirmed only by a human watching one. Whatever ships, the twin path will be
unwitnessed until someone has twins.

## Naming them, which is where this started

**No automatic rule can name twins usefully.** The default short name is the
first word of the EDID name through the character rule
(`windows/install.ps1:2183`, `macos/lib/walkthrough.sh:680`); two identical
panels produce the same first word and collide. Suggesting the manufacturer
instead collides identically -- and would suggest the three-letter PNP code
(`GSM`, `AUS`) rather than a brand, since that is all the EDID vendor id decodes
to (`windows/trigger-kvm.ps1:438-443`).

The names people want are positional -- `dell-left`, `dell-right` -- and the tool
cannot know position. The connector string helps when the two differ and does not
when both are on DisplayPort. **The only source of "which one is on the left" is
the person**, and `configure` already has the mechanism for asking: the check
flow makes a human watch a panel move (`specs/configure.md` §10, hard rule 3).
Switch one, ask which moved, name it accordingly. The existing duplicate refusal
(`specs/configure.md:460-469`) already forces the choice to be made.

So the naming question and the identity question are separate, and the twin case
argues neither for nor against changing the default suggestion.

## The cheap part -- SHIPPED as revision 13, 2026-09-05

Making the ambiguity visible instead of silent turned out to stand entirely on
its own, and it is now specified (`specs/configure.md` §6.4, `specs/status.md`
§5) and built on Windows. It converts "one of my monitors randomly stopped
following" into a sentence naming the cause, and it was **verifiable without
twins**, from a fixture -- `windows/tests/identity.tests.ps1`.

It was the same move as option D in `knowing-which-input-you-are-on.md`: make the
failure cheap to recover rather than impossible to detect. Left here rather than
deleted because it is the last row of the resolution table above -- whatever the
tiebreak eventually does, the refusal underneath it is the behaviour that was
already needed, and is now the thing it degrades to.

## What macOS would owe

One rule, on the familiar shared-key / per-platform-vocabulary pattern: read
`display.<label>.output`, and where it is absent behave exactly as today. The
vocabulary is its own -- macOS would need to decide what its stable per-port
handle is, and `AGENTS.md` already warns that the CoreGraphics UUID is not one
(it derives from the per-input product id). Not required to look anything like
Windows'.

It reaches macOS the way everything does: spec first, then this platform's
implementation, then a `specs/CHANGELOG.md` entry and this platform's
`SPEC-REVISION`, then the push. Not by editing `macos/`.

## Rejected while drafting

**Layering the EDID serial underneath the port as a first-choice tiebreak.** It
has exactly one advantage -- it survives a cable move between ports -- and the
port mechanism has to exist underneath it anyway, so it is a second mechanism
bought to cover a rare event the port tiebreak already announces. That is
structure which has not earned its existence. Recorded here so it is not
re-proposed from first principles.

**Rewritten 2026-09-05, because its original reason was wrong.** This entry used
to say the serial "would be absent on some panels" on the strength of the ASUS's
`0x01010101`. Descriptor `0xFF` then turned out to be populated on *both* panels
here, so that premise is false and is not what carries the rejection. What
carries it is weaker but still standing: descriptor `0xFF` is **optional** in the
EDID standard, so a panel without one is a case the design must handle whatever
this desk shows; and n=2 on one desk says nothing about the property that would
actually matter, which is whether two units of the SAME model carry *different*
strings. Nobody here has twins to check that on. A tiebreak whose discriminating
power is untested on the only case it exists for does not displace one that is
measured.

**So the port stays the design, and this is now a live alternative rather than a
closed one.** If someone turns up with two identical panels, the cheap first
measurement is whether their `0xFF` strings differ -- and if they do, the
trade-off (survives a cable move; needs the port path underneath anyway for
panels lacking the descriptor) is worth re-arguing rather than re-reading.

**Parsing EDID descriptor `0xFF` in the switcher.** Not needed by the design
above, and it is worth noting how it would have to be done if it ever is: WMI
surfaces the string today (`WmiMonitorID.SerialNumberID`, which is how it was
measured) but the boot tier may not use WMI as an identity source
(`windows/AGENTS.md`), so shipping code would parse the descriptor out of the
EDID block NVAPI already returns.

**Making the serial or the port a primary key rather than a tiebreak.** It would
break panel replacement: swap a monitor for an identical model and its
vendor:product still matches exactly one output, so under the design above the
stale qualifier is never consulted and the switch keeps working. As a primary key
it would refuse. This is the property that makes "consulted only on ambiguity"
load-bearing rather than merely cautious.
