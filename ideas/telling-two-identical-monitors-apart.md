# Telling two identical monitors apart

**Status:** exploratory. Nothing built, and it should not be built until the one
measurement below is taken. The sibling note for the same problem on the trigger
side is `telling-two-identical-devices-apart.md`, whose design is settled and
shipped (revision 12); much of the reasoning here is that argument re-checked
against displays rather than re-derived.

The question this started from: what happens if someone attaches two identical
monitors? Nobody here owns a pair, so every claim about the two-panel case is
reasoning, not measurement, and is marked as such.

## What happens today

Identity is the EDID vendor:product pair and nothing else, and two identical
panels are one identity. That breaks at three layers.

**Identification -- and the two platforms disagree, which is its own defect.**
Windows `list` unions rows **on the EDID key** (`windows/trigger-kvm.ps1:1015-1043`,
`$rows[$key] = ...`), so two identical panels would produce **one row**:
`monitors found (1)`, one row in the Monitors menu, the second panel silently
overwritten. macOS `wt_load_found` does not dedupe
(`macos/lib/walkthrough.sh:210-223`) so it would list two rows -- but
`wt_answer_index` looks answers up by that same key (`:200-208`, used at `:675`),
so both rows resolve to one answer record and configuring the second overwrites
the first. Neither platform can give them separate names, because the label is
keyed to the identity.

**Control -- fail-closed, and correct.** `Resolve-Panel` refuses on more than one
match (`windows/trigger-kvm.ps1:851-864`), macOS likewise
(`macos/lib/display.sh:63-85`). Picking the first would reintroduce the
order-dependence EDID matching exists to remove. The panel simply never switches.

**Discoverability -- a log line and nothing else.** `status` does not predict the
ambiguity, so this presents as "one of my monitors stopped following" with the
reason in a file the user may not know exists. Same failure class the trigger
side fixed in revision 12.

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

Descriptor `0xFF` (the ASCII serial string) is unparsed and might carry a real
one where the numeric field does not. That is a real option, and it is
deliberately not being pursued: see "Rejected while drafting".

## THE DESIGN: the port, as a tiebreak, consulted only on ambiguity

The same shape the trigger side settled on -- identity in fields, an optional
qualifier, reached only when the identity is ambiguous, and announced whenever
it is used.

```
display.left.vendor  = 0x10AC
display.left.product = 0x41A2
display.left.output  = 0x00000100     # tiebreak; consulted ONLY on ambiguity
```

Resolution becomes:

| outputs matching vendor:product | outcome |
|---|---|
| exactly one | match it -- **`output` is not consulted, so a cable move costs nothing** |
| none | refuse, as today |
| several, one at `output` | **the tiebreak decides -- the case vendor:product alone cannot** |
| several, none at `output` | still ambiguous: refuse, as today, and say so in `status` |

On Windows the value is NVAPI's `OutputId`
(`windows/trigger-kvm.ps1:245`, `:493`, `:507`). Its contents are the platform's,
on the same shared-key / per-platform-vocabulary pattern as `transport`
(revision 9): a config is machine-local and never copied between hosts.

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

## What must be measured before any of this is built

**Is `OutputId` a port identity or a per-boot handle?** If it does not survive a
reboot the design collapses. This repo has been burned by exactly this class of
NVAPI field before: `nvapi-transport.md` records `isActive` reading `False` then
`True` in one session with nothing changed, and *"what it tracks is not
established."*

A pre-reboot baseline is recorded in `../docs/measurements.md` (2026-09-05): LG
`0x00000200`, ASUS `0x00000100`. Re-read after a restart and compare. Worth
settling in the same pass: whether `displayId` (system-unique per NVAPI) is a
better key than `OutputId` (a per-GPU bitmask two GPUs could collide on).

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

## The cheap part, which stands on its own

**Make the ambiguity refusal visible in `status`.** Today the refusal is correct
and invisible. Saying it in words converts "one of my monitors randomly stopped
following" into a sentence naming the cause, and it is buildable and
**verifiable today without twins**, because the refusal path can be driven from
a fixture. It is also the necessary fallback for the last row of the resolution
table above, so it is not wasted work if the tiebreak is never built.

This is the same move as option D in `knowing-which-input-you-are-on.md`, which
shipped for the same reason: make the failure cheap to recover rather than
impossible to detect.

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
2026-09-05 measurement says it would be absent on some panels, so the port
mechanism has to exist underneath it anyway. Paying for a second mechanism, live
on some fraction of desks, to cover a rare event the port tiebreak already
announces, is structure that has not earned its existence. Recorded here so it is
not re-proposed from first principles.

**Parsing EDID descriptor `0xFF` to find a better serial.** Same reasoning: it
would improve the serial option, and the serial option is not the one being
taken. Worth revisiting only if `OutputId` turns out not to survive a reboot, at
which point this becomes the fallback design and the descriptor is the first
thing to measure.

**Making the serial or the port a primary key rather than a tiebreak.** It would
break panel replacement: swap a monitor for an identical model and its
vendor:product still matches exactly one output, so under the design above the
stale qualifier is never consulted and the switch keeps working. As a primary key
it would refuse. This is the property that makes "consulted only on ambiguity"
load-bearing rather than merely cautious.
