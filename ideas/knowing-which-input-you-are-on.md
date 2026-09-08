# Knowing which input you are on

**The tool is TOLD which input each computer is on, and cannot discover it.**
This note is about whether that has to stay true. What shipped from it is
`specs/status.md` 3: `status` shows the map and says nothing can verify it.

## The hole

A cable moved to a different input **on the monitor** splits by panel. The LG's
EDID product id is per-input, so the new input reports a product the config
does not have, zero matches, refusal: safe. The ASUS reports `0x42E0` on every
input, so it resolves perfectly and `pull` sends the old value; the panel
switches to an input with nothing on it, black, with a success in the log.
Recovery is the monitor's input button and `configure`.

Nothing can detect it: hard rule 2 forbids reading the value back (and on an
inactive link both panels lie), hard rule 3 says a success code proves nothing.

## What is knowable for free

- EDID vendor and product, already read for identity on every switch.
- On the LG that product id IS the input (`0x9e9d` DP, `0x9e9e` HDMI 1,
  `0x9e9f` USB-C; the input decides it, not the host). The signal exists on the
  panel that already fails safely and is absent on the one that fails
  dangerously.
- Connector type (HDMI vs DisplayPort) from NVAPI: narrows, never decides.

## Ideas still open

- **A. Product-id -> input map, so an LG re-plug self-heals.** Store the
  measured product id beside each input; `pull` reads its own EDID product and
  sends that input's value. A per-desk mapping chore (plug into each input in
  turn) that cannot be shipped as a table, and does nothing for the ASUS. Small;
  worth doing only if it falls out of other `configure` work.
- **C. Record the EDID serial and refuse on a mismatch.** Catches a different
  *panel*, not a different *input*; overlaps the ambiguity refusal.

## Closed: "make me the active source"

A protocol command meaning *switch to the input this message arrived on* would
make the map unnecessary. It does not exist for a desktop GPU:

- Not in DDC/CI: MCCS `0x60` and LG's `0xF4` are enumerated selectors.
- HDMI CEC "One Touch Play" has the right semantics, but no desktop GPU wires
  out the CEC pin (NVIDIA staff, developer forum, 2013-2015); the workaround is
  an inline USB-CEC adapter per link, a second box to install.
- DisplayPort CEC-Tunneling-over-AUX (DPCD `0x3000`, `drm_dp_cec.c`) exists for
  DP-to-HDMI adapters reaching a downstream HDMI sink, most adapters do not wire
  the pin, and there is no MST support. A native DP sink accepting it is
  unevidenced.

And it would be refused anyway: the behaviour wished for already exists as the
monitors' auto-input feature, marked MUST BE OFF in `displays.toml`, because a
panel cannot distinguish "this computer wants focus" from "this computer woke
up for a backup". A protocol-level version is the same hazard with better
manners.

## References

Retrieved 2026-09-01: Linux `drivers/gpu/drm/display/drm_dp_cec.c` and
`include/drm/display/drm_dp.h`; NVIDIA Developer Forums, "HDMI-CEC Support?"
(<https://forums.developer.nvidia.com/t/hdmi-cec-support/31445>); ddcutil,
"DDC and DisplayPort" (<https://www.ddcutil.com/displayport/>); CEC-O-MATIC
(<https://www.cec-o-matic.com/>).
