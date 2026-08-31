#!/bin/bash
#
# pull, to, list and the refusals -- driven through the real program, not
# through its parts.
#
# The suite cannot move a monitor: M1DDC points at a recorder and display-probe
# at a fixture, both set up by lib.sh. That is deliberately a stronger guarantee
# than stubbing a shell function, because it holds for code paths a test did not
# anticipate -- the only m1ddc this program can find writes a line to a file.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../lib/common.sh
. "$MAC_DIR/lib/common.sh"
# shellcheck source=../lib/config.sh
. "$MAC_DIR/lib/config.sh"
# shellcheck source=../lib/display.sh
. "$MAC_DIR/lib/display.sh"

fake_setup
fake_displays "$FAKE_LG" "$FAKE_ASUS"
CFG=$(printf '%s' "$CONFIG_THIS_DESK" | make_config)

# One write per switch here, so an assertion reads as one line per panel. The
# real default is two, and there is a test for that below.
export TK_TRIES=1

LG_UUID=AAAAAAAA-0000-4000-8000-000000000001
ASUS_UUID=BBBBBBBB-0000-4000-8000-000000000002

# =============================================================================
# THE PACKETS -- the cross-platform contract
#
# These bytes are copied from ../../displays.toml, which is the source of truth
# shared with the Windows implementation. If this test and that file disagree,
# one of the two platforms is putting different bytes on the same wire, which
# presents as a half-switching desk and reads as a hardware fault.
# =============================================================================

it 'builds the exact LG packets in displays.toml'
assert_equal '50 84 03 F4 00 D0 9D' "$(ddc_packet_for lg-alt 208)" 'LG -> DisplayPort'
assert_equal '50 84 03 F4 00 D1 9C' "$(ddc_packet_for lg-alt 209)" 'LG -> USB-C'

it 'builds the exact ASUS packets in displays.toml'
assert_equal '51 84 03 60 00 11 C9' "$(ddc_packet_for standard 17)" 'ASUS -> HDMI 1'
assert_equal '51 84 03 60 00 0F D7' "$(ddc_packet_for standard 15)" 'ASUS -> DisplayPort'

it 'refuses to build a packet for an unknown method'
set +e; out=$(ddc_packet_for nonsense 15); rc=$?; set -e
assert_true "$(( rc != 0 ? 0 : 1 ))"
assert_equal '' "$out"

# =============================================================================
# pull and to
# =============================================================================

it 'pull points every configured monitor at computer.this'
# Panels go in sorted label order -- asus before lg -- which is what the
# PowerShell reader does too (Sort-Object -Unique). Order is not otherwise
# meaningful: every value is resolved before any of them is sent.
fake_reset
run_tk pull --config "$CFG"
assert_equal 0 "$TK_RC" "$TK_OUT"
assert_sent "display $ASUS_UUID set input 15
display $LG_UUID set input-alt 209"

it 'to pc points them at the other computer, from the same map'
fake_reset
run_tk to pc --config "$CFG"
assert_equal 0 "$TK_RC" "$TK_OUT"
assert_sent "display $ASUS_UUID set input 17
display $LG_UUID set input-alt 208"

it '--only moves one panel and leaves the other alone'
fake_reset
run_tk pull --only asus --config "$CFG"
assert_equal 0 "$TK_RC" "$TK_OUT"
assert_sent "display $ASUS_UUID set input 15"

it 'sends each write twice by default, because the bus is lossy'
fake_reset
export TK_TRIES=''          # fall back to the shipped default
run_tk pull --only asus --config "$CFG"
assert_sent "display $ASUS_UUID set input 15
display $ASUS_UUID set input 15"
export TK_TRIES=1

it 'a dry run prints the packet and sends nothing'
fake_reset
run_tk pull --dry-run --config "$CFG"
assert_equal 0 "$TK_RC"
assert_match "$TK_OUT" '50 84 03 F4 00 D1 9C'
assert_match "$TK_OUT" '51 84 03 60 00 0F D7'
assert_nothing_sent 'a dry run must not reach the transport'

it 'aims each write at the UUID the EDID resolved to, never at an index'
fake_reset
run_tk pull --config "$CFG"
assert_match "$(fake_sent)" "$LG_UUID"
assert_no_match "$(fake_sent)" 'display 1 '

# =============================================================================
# THE FOUR REFUSALS -- each must send NOTHING
#
# Not "a check ran" but "the wire is empty". On Windows the null check was
# present, did not fire, and an unresolved value went out as 0x00 -- an input no
# monitor has -- so every switch silently did nothing and said nothing.
# =============================================================================

it "refuses 'to' with a name no panel knows, and sends nothing"
fake_reset
run_tk to nosuch --config "$CFG"
assert_equal 2 "$TK_RC"
assert_match "$TK_OUT" 'REFUSING'
assert_match "$TK_OUT" 'it knows: mac pc'
assert_nothing_sent

it 'refuses when ONE panel does not know the computer, and moves NEITHER'
# A half-applied arrangement leaves the desk in a state nobody configured, and
# you have to work out which half landed.
fake_reset
half=$(printf '%s' "$CONFIG_THIS_DESK" | grep -v 'asus.input.0x11' | make_config)
run_tk to pc --config "$half"
assert_equal 2 "$TK_RC"
assert_nothing_sent 'the LG could have moved and must not have'

it 'refuses a panel that names no computers at all, and sends nothing'
fake_reset
bare=$(make_config <<'EOF'
computer.this = mac
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.method  = lg-alt
EOF
)
run_tk pull --config "$bare"
assert_equal 2 "$TK_RC"
assert_match "$TK_OUT" 'it names no computers at all'
assert_nothing_sent

it 'refuses an unparseable input value, and sends nothing'
fake_reset
bad=$(make_config <<'EOF'
computer.this = mac
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.method  = lg-alt
display.lg.input.0xZZ = mac
EOF
)
run_tk pull --config "$bad"
assert_equal 2 "$TK_RC"
assert_nothing_sent 'an unparseable value must not become 0x00 on the wire'

it 'refuses a missing computer.this, and sends nothing'
fake_reset
noself=$(printf '%s' "$CONFIG_THIS_DESK" | grep -v '^computer.this' | make_config)
run_tk pull --config "$noself"
assert_equal 2 "$TK_RC"
assert_match "$TK_OUT" 'computer.this is missing'
assert_nothing_sent

it 'refuses when two inputs name the same computer, and sends nothing'
fake_reset
amb=$(make_config <<'EOF'
computer.this = mac
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.method  = lg-alt
display.lg.input.0xD1 = mac
display.lg.input.0xD0 = mac
EOF
)
run_tk pull --config "$amb"
assert_equal 2 "$TK_RC"
assert_match "$TK_OUT" 'more than one input'
assert_nothing_sent

it 'refuses an unparseable EDID id rather than matching vendor 0x0000'
fake_reset
badedid=$(make_config <<'EOF'
computer.this = mac
display.lg.vendor  = nonsense
display.lg.product = 0x9E9F
display.lg.method  = lg-alt
display.lg.input.0xD1 = mac
EOF
)
run_tk pull --config "$badedid"
assert_equal 1 "$TK_RC"
assert_match "$TK_OUT" 'no usable EDID'
assert_nothing_sent

it 'refuses a config with no displays at all'
fake_reset
run_tk pull --config "$FAKE_DIR/no-such-config"
assert_equal 2 "$TK_RC"
assert_match "$TK_OUT" 'no displays configured'
assert_nothing_sent

it 'refuses an --only naming a display the config does not have'
fake_reset
run_tk pull --only nope --config "$CFG"
assert_equal 2 "$TK_RC"
assert_match "$TK_OUT" 'Known:'
assert_nothing_sent

# =============================================================================
# RESOLVING A PANEL -- fails closed on both sides of "exactly one"
# =============================================================================

it 'refuses when no attached display identifies as the configured one'
fake_reset
fake_displays "$FAKE_ASUS"
run_tk pull --only lg --config "$CFG"
assert_equal 1 "$TK_RC"
assert_match "$TK_OUT" 'no display identifies as it'
assert_nothing_sent

it 'refuses when TWO displays identify as the same panel'
# Picking the first would reintroduce exactly the order-dependence that matching
# on the EDID exists to remove.
fake_reset
fake_displays "$FAKE_LG" "$FAKE_LG"
run_tk pull --only lg --config "$CFG"
assert_equal 1 "$TK_RC"
assert_match "$TK_OUT" 'ambiguous'
assert_nothing_sent

it 'does not confuse a panel with one whose id differs by a single digit'
# The LG reports 0x9E9D on the Windows host's DP cable and 0x9E9F on this Mac's
# USB-C. Copying an id between hosts must match nothing, not the wrong panel.
fake_reset
fake_displays '1E6D|9E9D|GSM|DP|00001111|11111111-1111-1111-1111-111111111111|LG ULTRAGEAR+'
run_tk pull --only lg --config "$CFG"
assert_equal 1 "$TK_RC"
assert_nothing_sent

fake_displays "$FAKE_LG" "$FAKE_ASUS"

# =============================================================================
# THE SERVICE-CHANNEL GATE -- AGENTS.md hard rule 5
#
# I2C source 0x50 is LG's service/factory channel; sweeping it has bricked LG
# monitors. The gate lives in the same function as the only occurrence of
# `input-alt`, so there is no path to it that skips the check.
# =============================================================================

it 'REFUSES the LG channel on a non-LG panel, and sends nothing'
# The point of the rule's shape: method = lg-alt on a non-GSM panel makes the
# write refuse. It does not make the write happen.
fake_reset
wrong=$(make_config <<'EOF'
computer.this = mac
display.asus.vendor  = 0x06B3
display.asus.product = 0x42E0
display.asus.method  = lg-alt
display.asus.input.0x0F = mac
EOF
)
run_tk pull --config "$wrong"
assert_equal 1 "$TK_RC"
assert_match "$TK_OUT" 'REFUSING to send the LG service channel'
assert_nothing_sent 'source 0x50 must never reach a non-GSM panel'

it 'allows the LG channel on the LG'
fake_reset
run_tk pull --only lg --config "$CFG"
assert_sent "display $LG_UUID set input-alt 209"

it 'refuses an unknown method rather than defaulting to a channel'
fake_reset
unk=$(printf '%s' "$CONFIG_THIS_DESK" | sed 's/method  = standard/method  = nonsense/' | make_config)
run_tk pull --only asus --config "$unk"
assert_equal 1 "$TK_RC"
assert_match "$TK_OUT" "unknown method"
assert_nothing_sent

it 'reaches the service channel from exactly one function in the sources'
# The structural half of hard rule 5, checked mechanically rather than by
# reading. `input-alt` is what m1ddc calls I2C source 0x50; if it ever appears
# outside ddc_send, there is a second way to reach the sidechannel and the gate
# is no longer a gate.
hits=$(grep -rn 'input-alt' "$MAC_DIR/lib" "$TK" | grep -vc '^[^:]*:[0-9]*: *#')
assert_equal 1 "$hits" 'input-alt must appear in exactly one non-comment line'
# shellcheck disable=SC2016  # a literal to grep for, not an expansion
owner=$(grep -rln 'set "$_sub"' "$MAC_DIR/lib")
assert_equal "$MAC_DIR/lib/display.sh" "$owner"

# =============================================================================
# list
# =============================================================================

it 'list shows each panel with its EDID ids and its own name'
run_tk list --config "$CFG"
assert_equal 0 "$TK_RC"
assert_match "$TK_OUT" '0x1E6D'
assert_match "$TK_OUT" '0x9E9F'
assert_match "$TK_OUT" 'LG ULTRAGEAR+'
assert_match "$TK_OUT" 'PG42UQ'

it 'list says which configured label each panel is'
assert_match "$TK_OUT" 'lg'
assert_match "$TK_OUT" 'asus'

it 'list warns that a product id is a local key'
assert_match "$TK_OUT" 'Never copy one from another host'

it 'list marks an attached panel that is not in the config'
fake_displays "$FAKE_LG" "$FAKE_ASUS" \
  '10AC|A123|DEL|HDMI|00000001|22222222-2222-2222-2222-222222222222|U2720Q'
run_tk list --config "$CFG"
assert_match "$TK_OUT" 'not in config'

it 'list --raw emits the rows for a caller to parse'
run_tk list --raw --config "$CFG"
assert_match "$TK_OUT" "1E6D|9E9F|GSM|DP|00001111|$LG_UUID|LG ULTRAGEAR+"

it 'list --raw puts NOTHING but rows on stdout'
# The walkthrough parses this. A log line mixed into it is a row the caller
# misreads, silently -- which is why tk_log writes to the host, not the
# pipeline.
raw=$("$TK" list --raw --config "$CFG" 2>/dev/null)
bad=$(printf '%s\n' "$raw" | grep -vc '^[0-9A-F]\{4\}|' || true)
assert_equal 0 "$bad" "non-row lines on stdout: $raw"

it 'a refusal reaches the user rather than being captured as a resolved panel'
# display_resolve prints the matched row on stdout and refuses on the host. When
# both went to stdout the refusal was swallowed into the caller's variable and
# nobody ever saw it.
fake_reset
fake_displays "$FAKE_ASUS"
err=$("$TK" pull --only lg --config "$CFG" 2>&1 >/dev/null || true)
assert_match "$err" 'no display identifies as it'
fake_displays "$FAKE_LG" "$FAKE_ASUS"

it 'list moves nothing'
assert_nothing_sent 'list must never reach the transport'

finish
