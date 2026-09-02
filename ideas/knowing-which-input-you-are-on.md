# Knowing which input you are on

The question this started from: if someone unplugs a monitor from their GPU to
use it elsewhere and later plugs it back into a *different* port, does
trigger-kvm still work?

Mostly yes -- and the "mostly" hides a real hole. Chasing it turns into one
question: **the tool is TOLD which input each computer is on, and cannot
discover it.** Everything below is about whether that has to stay true.

## What happens today on a re-plug

Three cases, and they behave completely differently. `Resolve-Panel`
(`windows/trigger-kvm.ps1`) matches on EDID vendor+product, re-enumerated on
every switch; no port, `outputId`, index or handle is ever persisted.

**1. A different port on the same GPU -- fine.** EDID is a property of the panel
and the panel's input, not of the socket the other end sits in. Vendor+product
are unchanged, the `outputId` is discovered fresh, the switch works. This is
what the "do not hardcode display indices" convention buys.
*Reasoned from the code, not measured -- see Unfinished below.*

**2. A different GPU -- refuses, loudly.** Measured 2026-09-01: NVAPI cannot see
a panel on another adapter at all, so it is 0 matches and a refusal naming the
EDID it wanted. Same thing happens while the monitor is unplugged entirely.
Correct, logged, no wrong write.

**3. A different input ON THE MONITOR -- this is the hole**, and it is not the
case the question was about. It splits by panel:

- **LG**: its EDID product id is *per-input* (four values measured on one panel).
  A new input reports a product the config does not have -> 0 matches -> refuse.
  Safe, loud, recoverable by re-running `configure`.
- **ASUS**: reports `0x42E0` on every input. So it resolves **perfectly**, and
  then sends `0x11` (HDMI 1) while the computer is actually on HDMI 2. The panel
  obediently switches to an input with nothing on it. **Black screen, silently,
  with a success in the log.**

The ASUS case is the one worth fixing. It is recoverable -- DDC still reaches a
panel over a link it is not currently displaying, measured 2026-09-01 -- so
`trigger-kvm set` with the right value gets it back. But nothing detects it and,
under the hard rules, nothing can: rule 2 forbids reading the value back, rule 3
says a success code proves nothing. **The config's input map is an assertion
about physical cabling that the tool has no way to check.**

## The constraint everything else follows from

The same one as `unknown-monitor-discovery.md`, and it is worth restating because
it kills most of the obvious answers: **we cannot verify a switch.** Every route
ends in *write a value, ask the human what appeared*. So nothing below may become
a detector that gates a switch. An unreliable signal that shortens a list is safe;
one that decides where to send a write is not.

Reading VCP `0x60` back deserves a specific burial. On the *active* link it
returns the input being displayed -- which is the input you are on, but only when
you are already displayed, i.e. exactly when you do not need to pull. On an
inactive link both panels here lie (the PG42UQ returns 0 for everything; the LG
returns -7 while renegotiating). It answers the wrong question, unreliably, and
rule 2 forbids it. Not a route.

## What is knowable for free, today

- **EDID vendor and product**, from NVAPI, already read for identity on every
  switch. No DDC read, no I2C traffic, nothing rule 2 touches.
- **And on some panels that product id IS the input.** The LG reports `0x9e9d`
  on DisplayPort, `0x9e9e` on HDMI 1, `0x9e9f` on USB-C -- measured, and the
  INPUT decides it, not the host: two different Macs on the same input read the
  same value. So on that panel a machine genuinely can tell which input it is
  plugged into, without asking the monitor anything.
- **Connector type** (HDMI vs DisplayPort) from NVAPI. Narrows, never decides:
  it is the GPU-side connector, and HDMI 1 and HDMI 2 look identical through it.

**The asymmetry is the whole problem.** The signal exists on the panel that
already fails safely, and is absent on the panel that fails dangerously. The
ASUS is `0x42E0` everywhere; there is nothing to read.

## Ideas

**A. Product-id -> input map, so an LG re-plug self-heals.** Store the measured
product id alongside each input in the config. `pull` reads its own EDID product,
looks up which input that is, sends that value. A re-plug into a known input then
just works instead of refusing.

*Cost:* a per-desk mapping chore -- plug into each input in turn and record what
it reports -- and the repo's own rule forbids shortcutting it by copying values
between hosts, so it cannot be shipped as a table. *Verdict:* real but small. It
upgrades the LG from "refuses, go re-run configure" to "just works", and does
nothing at all for the ASUS. Worth doing only if it falls out of other work on
`configure`.

**B. Notice that a panel's product id changed, and refuse instead of writing.**
This is what already happens for the LG, by accident of it having 0 matches.
There is no equivalent for a panel with a stable id, because nothing changed to
notice. *Verdict:* not implementable for the case that needs it.

**C. Record the EDID *serial* too, and refuse on a mismatch.** Would catch a
different *panel*, not a different *input* -- the LG's serial is stable across all
four inputs (measured). *Verdict:* solves a different problem. Might still be
worth it against "someone swapped the monitor for an identical model", which is
the case `Resolve-Panel`'s ambiguity refusal half-covers today.

**D. Make the failure cheap to recover instead of impossible to detect.** —
**SHIPPED 2026-09-02.** `status` states which input each computer is asserted to
be on and that the tool cannot verify it, with `configure` named as the fix. The
contract is now `specs/status.md` §3 (revision 8); it is normative because the
wording IS the remedy, and it moved there rather than staying here. Nothing about
D remains to design.

**E. Ask the panel to switch to "whoever is talking", not to a named input.**
This is the appealing one, and it does not exist. See below.

## "Make me the active source" -- the protocol research

The wish is a command meaning *switch to the input this message arrived on*,
which would make the input map unnecessary and close case 3 entirely. Findings:

**Not in DDC/CI.** MCCS `0x60` is an enumerated selector; every value names a
specific physical input. LG's `0xF4` sidechannel is the same shape on a different
I2C source. Neither `displays.toml` table has anything else, and per hard rule 1
the way to find out otherwise is vendor documentation, never experiment --
`0xF4` lives on a service channel where experimenting has bricked panels.

**It exists in HDMI, as CEC "One Touch Play".** CEC-O-MATIC groups the feature as
`Active Source`, `Image View On` and `Text View On` -- exactly the right
semantic: a source device announces itself and the sink switches to it.

**But no desktop GPU can speak it.** NVIDIA's own X driver engineer, on NVIDIA's
developer forum: *"CEC is supported on Tegra but when I looked into it a while
back, I found that it was not possible to support it on desktop GPUs"*
(2015-09-18), and then *"CEC is still not supported on desktop GPU boards"*
(2015-10-12), after an earlier *"We don't have any plan to support it"*
(2013-11-21). The CEC pin is simply not wired out on desktop boards. The
workaround people use is an inline USB-CEC adapter (Pulse-Eight and similar) that
intercepts the CEC pin and exposes it over USB -- an extra dongle per HDMI link,
plus libCEC. **That is a second physical box and a second thing to install, which
is the same objection that rules out a second watcher process.**

**DisplayPort has a CEC mechanism, and it is not the one we would want.**
CEC-Tunneling-over-AUX is real and implemented in Linux (`drm_dp_cec.c`,
`CONFIG_DRM_DP_CEC`), living in a DPCD register block at `0x3000`
(`DP_CEC_TUNNELING_CAPABILITY` `0x3000`, `DP_CEC_TUNNELING_CONTROL` `0x3001`,
`DP_CEC_RX_MESSAGE_BUFFER` `0x3010`, `DP_CEC_TX_MESSAGE_BUFFER` `0x3020`, from
the kernel's `drm_dp.h`). Three things sink it for us:

1. **It is for DP-to-HDMI adapters, to reach an HDMI sink downstream** -- it
   tunnels CEC through the DP link to a converter, rather than giving a DP
   monitor a "become active" command. Our LG is a native DP sink; there is no
   downstream HDMI device for the CEC to be for.
2. **Even the adapters mostly do not work.** The kernel source is blunt: *"Quite
   a few active (mini-)DP-to-HDMI or USB-C-to-HDMI adapters have a converter chip
   that supports CEC-Tunneling-over-AUX (usually the Parade PS176), but they do
   not wire up the CEC pin, thus making CEC useless."*
3. **No MST support:** *"the current implementation does not support CEC over an
   MST hub. As far as I can see there is no mechanism defined in the DisplayPort
   standard to transport CEC interrupts over an MST device."*

Whether any *monitor* advertises `0x3000` for itself is unknown -- the register
block is defined for any DP sink, so it is not impossible, but every
implementation found in the wild is an adapter, and CEC's own semantics are about
a sink switching to a downstream source, not about a monitor selecting among its
own physical inputs. Treat "a DP monitor could accept One Touch Play" as
unevidenced.

**USB-C adds nothing.** DP Alt Mode carries native DisplayPort negotiated over
USB-PD structured VDMs; the video path is DisplayPort, so it inherits exactly the
DP answer above. USB-C monitors often *do* jump to the USB-C input on connect,
but that is the vendor's auto-input behaviour, not a command a host can issue.

**Which lands on the irony worth recording.** The behaviour being wished for --
"show whoever has a live signal, whichever port that is" -- already exists in both
panels, as *Auto Input Switch* (LG) and *Auto Input Detection* (ASUS). Both are
marked **MUST be OFF** in `displays.toml`, because the panel cannot distinguish
"this machine wants focus" from "this machine woke up for a Time Machine run",
and on sleep it defects to the other live input. It is the same reason wake is
not allowed to become a trigger. **The feature is available, and it is the
enemy** -- what this project sells is precisely that switching happens when a
human moves the peripherals and at no other time. A protocol-level "make me
active" would be the same hazard with better manners, and would need the same
question answered: what stops it firing when nobody asked?

That is the real finding. Case 3 is not waiting on a missing protocol command.
Even a perfect one would be refused on the same grounds auto-input is.

## Unfinished

- **Case 1 is not measured.** The 2026-09-01 cable move changed the GPU *and* the
  adapter, so it does not isolate "same GPU, different port". The clean test: the
  LG is on a 4090 DisplayPort and the card has spare DP sockets, so moving only
  the GPU end -- same cable, same LG input -- isolates it. Terminal goes on the
  ASUS first (hard rule 4). Cheap; just not done.
- Whether the PG42UQ implements CEC on its HDMI inputs at all was not researched,
  because the GPU cannot reach it either way.
- The per-input product ids for the LG's `hdmi1`/`hdmi2` are unmeasured, so idea
  A could only cover the inputs this desk actually uses.

## References

Retrieved 2026-09-01.

- Linux kernel, `drivers/gpu/drm/display/drm_dp_cec.c` --
  <https://raw.githubusercontent.com/torvalds/linux/master/drivers/gpu/drm/display/drm_dp_cec.c>
  (adapter quote, MST limitation)
- Linux kernel, `include/drm/display/drm_dp.h` --
  <https://raw.githubusercontent.com/torvalds/linux/master/include/drm/display/drm_dp.h>
  (DPCD `0x3000` CEC block addresses)
- NVIDIA Developer Forums, "HDMI-CEC Support?" --
  <https://forums.developer.nvidia.com/t/hdmi-cec-support/31445>
  (NVIDIA staff statements, 2013-2015)
- ddcutil documentation, "DDC and DisplayPort" -- <https://www.ddcutil.com/displayport/>
  (DDC is I2C tunneled over AUX; no input-identity mechanism is described)
- CEC-O-MATIC -- <https://www.cec-o-matic.com/> (One Touch Play message set)

Not verified, and deliberately not relied on above: the specific DisplayPort
spec revision that introduced CEC tunneling (reported as 1.3, with the register
detail in 1.4a) -- VESA specifications are paywalled and were not retrieved. The
kernel header is cited instead for the register facts, which is what the argument
actually rests on. Numeric CEC opcodes were likewise not confirmed from a primary
source and are omitted.
