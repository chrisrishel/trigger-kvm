#!/bin/bash
#
# `discover` -- what is attached, in the form the config wants.
#
# The display half runs against a fixture; the device half runs against this
# real machine, because that is the half whose whole job is to report what is
# actually here. Nothing here can move a monitor: M1DDC points at a recorder.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ ! -x "$MAC_DIR/event-watch" ]; then
  echo "event-watch is not built; run: make" >&2
  exit 1
fi

fake_setup
fake_displays "$FAKE_LG" "$FAKE_ASUS"
# The DEVICE half runs against the real binary and this real machine, because
# reporting what is actually attached is its whole job. fake_setup points
# TK_WATCHER at a fixture for the tests that want one; this one does not.
export TK_WATCHER="$MAC_DIR/event-watch"
CFG=$(printf '%s' "$CONFIG_THIS_DESK" | make_config)
export TK_TRIES=1

run_tk discover --config "$CFG"
OUT=$TK_OUT

it 'succeeds'
assert_equal 0 "$TK_RC" "$OUT"

# =============================================================================
# displays: EDID vendor, product, and the panel's OWN name
# =============================================================================

it 'shows every attached display with its EDID vendor and product'
assert_match "$OUT" '0x1E6D'
assert_match "$OUT" '0x9E9F'
assert_match "$OUT" '0x06B3'
assert_match "$OUT" '0x42E0'

it "shows each panel's own name, from EDID descriptor tag 0xFC"
# Asking the hardware beats a table, which only ever knows the monitors its
# author owned.
assert_match "$OUT" 'LG ULTRAGEAR+'
assert_match "$OUT" 'PG42UQ'

it 'says which configured label each display is'
assert_match "$OUT" 'lg'
assert_match "$OUT" 'asus'

it 'marks an attached display the config does not know about'
fake_displays "$FAKE_LG" \
  '10AC|A123|DEL|HDMI|00000001|22222222-2222-2222-2222-222222222222|U2720Q'
run_tk discover --config "$CFG"
assert_match "$TK_OUT" 'not in config'
fake_displays "$FAKE_LG" "$FAKE_ASUS"

# =============================================================================
# devices: USB now, and EVERY paired Bluetooth device
# =============================================================================

run_tk discover --config "$CFG"
OUT=$TK_OUT

it 'lists USB devices attached right now'
assert_match "$OUT" 'usb:046d:0843'
assert_match "$OUT" 'attached now'

it 'lists every PAIRED Bluetooth device, connected or not'
# Two different questions, and conflating them cost the Windows side a round:
# firing is on connected, OFFERING is on paired. A trigger fires on arrival, so
# the device that is disconnected right now is exactly the one that will produce
# one -- filtering the list to connected-only hid the choice a user most wants.
assert_match "$OUT" 'paired, not connected'

it 'shows Bluetooth connection state, and does not filter on it'
assert_match "$OUT" 'connected now'

it 'marks the devices that are currently configured as triggers'
assert_match "$OUT" 'currently a trigger'

it 'marks BOTH configured triggers, not just the first'
n=$(printf '%s\n' "$OUT" | grep -c 'currently a trigger' || true)
assert_equal 2 "$n"

it 'normalises a bare VVVV:PPPP in the config to a usb: key when marking'
# A config written before Bluetooth existed uses the bare form. Without
# normalising, every marker silently stopped appearing -- which reads as "none
# of these are configured" and is worse than no marker at all.
bare=$(printf '%s' "$CONFIG_THIS_DESK" |
       sed 's|^trigger.device.*|trigger.device = 046D:0843|' | make_config)
run_tk discover --config "$bare"
assert_match "$TK_OUT" 'usb:046d:0843'
assert_match "$TK_OUT" 'currently a trigger'

it 'says the full vendor+product pair must be matched'
assert_match "$OUT" 'vendor-only match fires'

it 'names the config file it is talking about'
assert_match "$OUT" "$CFG"

it 'moves nothing'
assert_nothing_sent 'discover must never reach the transport'

finish
