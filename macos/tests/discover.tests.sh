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
# The DEVICE half is driven from the harness's fixture list (fake_setup points
# TK_WATCHER at it), so what discover does with a row -- state, marker,
# normalisation -- is asserted against known rows. The real binary is run once
# at the end for its SHAPE only: which devices this machine has is its own
# business, and asserting a particular one made the suite a description of one
# desk that went red on every other.
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

# One connected Bluetooth device alongside the fixture's paired-but-absent one,
# so both states are on the page.
printf 'bt|bt:0011223344fe|connected now|Keyboard\n' >>"$TK_FAKE_DEVICES"
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

it 'the real watcher answers the device half, and its rows have the right shape'
# One owner of "what is attached": the walkthrough asks event-watch --list
# rather than keeping a second enumeration. Exercised here against the real
# binary for its format only -- see the header comment.
if [ -x "$MAC_DIR/event-watch" ]; then
  TK_WATCHER="$MAC_DIR/event-watch" run_tk discover --config "$CFG"
  assert_equal 0 "$TK_RC" "$TK_OUT"
  assert_match "$TK_OUT" '=== devices that could be a trigger ==='
  # specs/configure.md 7.1: the row leads with WHAT THE DEVICE IS and the id it
  # is matched on sits beside it. This asserted the reverse until revision 10 --
  # `^  usb:...` -- so the id is now found mid-row rather than anchored.
  rows=$(printf '%s\n' "$TK_OUT" | grep -E ' (usb:[0-9a-f]{4}:[0-9a-f]{4}|bt:[0-9a-f]{12}) ' || true)
  if [ -z "$rows" ]; then
    assert_match "$TK_OUT" '(none found)' 'no rows means it must say so'
  else
    bad=$(printf '%s\n' "$rows" |
          grep -vE ' (usb:[0-9a-f]{4}:[0-9a-f]{4}|bt:[0-9a-f]{12}) +(attached now|paired, not connected|connected now)' || true)
    assert_equal '' "$bad" 'malformed device rows from the real watcher'
    # The name column must not be empty: an id alone is not a choice anybody can
    # make, which is the whole point of 7.1.
    nameless=$(printf '%s\n' "$rows" | grep -E '^  +(usb|bt):' || true)
    assert_equal '' "$nameless" 'every row must lead with a name, not an id'
  fi
else
  skip_case 'event-watch is not built (run: make)'
fi

it 'says the full vendor+product pair must be matched'
assert_match "$OUT" 'vendor-only match fires'

it 'names the config file it is talking about'
assert_match "$OUT" "$CFG"

it 'moves nothing'
assert_nothing_sent 'discover must never reach the transport'

finish
