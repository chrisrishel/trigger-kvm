#!/bin/bash
#
# `status` -- specs/status.md.
#
# Two of its sections are behaviour rather than presentation, and both are here:
# the watcher question is answered from the LOCK and not by counting processes
# (2), and the input map must be shown together with the statement that nothing
# can verify it (3).
#
# Nothing here reaches launchd, a monitor or the real install: fake_setup points
# every helper at a recorder and HOME is a temp directory, so every path the
# program derives lands inside it.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_setup
export HOME="$FAKE_DIR/home"
mkdir -p "$HOME"

CFG="$FAKE_DIR/status.cfg"
printf '%s' "$CONFIG_THIS_DESK" >"$CFG"

# The lock query is the watcher's, so the harness's stand-in answers it too.
# TK_FAKE_LOCK_STATUS names what it should report; unset means "nobody holds it",
# which is the state of a machine with no watcher.
fake_lock() { TK_FAKE_LOCK_STATUS=$1; export TK_FAKE_LOCK_STATUS; }

cat >"$FAKE_DIR/event-watch" <<'EOS'
#!/bin/sh
case "$1" in
  --list) [ -f "$TK_FAKE_DEVICES" ] && cat "$TK_FAKE_DEVICES"; exit 0 ;;
  --test-trigger) exit "${TK_FAKE_TRIGGER_RC:-0}" ;;
  --lock-status)
    if [ "${TK_FAKE_LOCK_STATUS:-none}" = running ]; then echo running; exit 0; fi
    echo none; exit 1 ;;
esac
exit 0
EOS
chmod +x "$FAKE_DIR/event-watch"

# =============================================================================
# 2. the watcher is a STATE, answered from the lock
# =============================================================================

it 'reports a running watcher from the lock'
fake_lock running
run_tk status --config "$CFG"
assert_match "$TK_OUT" 'watcher  : running'

it 'and reports none when nothing holds the lock, with how to start one'
fake_lock none
run_tk status --config "$CFG"
assert_match "$TK_OUT" 'watcher  : none'
assert_match "$TK_OUT" 'trigger-kvm restart'

# The failure this replaces: `status` said `watchers : 0` beside a watcher that
# was running and firing, because it counted processes it could not see. Here
# the process table is irrelevant by construction -- no watcher of any kind is
# running under the suite, and the lock still decides the answer.
it 'takes the lock as the authority even though no process is running'
fake_lock running
run_tk status --config "$CFG"
assert_no_match "$TK_OUT" 'watchers :'
assert_match "$TK_OUT" 'watcher  : running'

# =============================================================================
# 3. the input map, and the claim it cannot make
# =============================================================================

it 'shows every configured panel with its inputs and the computer each names'
fake_lock running
run_tk status --config "$CFG"
assert_match "$TK_OUT" 'inputs   :'
assert_match "$TK_OUT" '0x0F -> mac (this one)'
assert_match "$TK_OUT" '0x11 -> pc'
assert_match "$TK_OUT" '0xD1 -> mac (this one)'
assert_match "$TK_OUT" '0xD0 -> pc'

it 'says in words that nothing can verify the map, and how to fix it'
assert_match "$TK_OUT" 'asserted, never verified'
assert_match "$TK_OUT" 'switches that panel to a dead input'
assert_match "$TK_OUT" 'Fix: trigger-kvm configure'

# 3.2: there is no signal behind a claim that the map is right, and nothing can
# check it -- so an offer to try is worse than the silence it replaces. Scoped to
# the inputs block: an unrelated line elsewhere containing one of these words is
# not this rule being broken, and a whole-output match would fail confusingly.
it 'never offers to check the map or hedges the warning'
_block=$(printf '%s\n' "$TK_OUT" | sed -n '/^inputs   :/,$p')
assert_true "$([ -n "$_block" ] && echo 0 || echo 1)" 'the inputs block must be findable'
assert_no_match "$_block" 'verify'
assert_no_match "$_block" 'check the map'
assert_no_match "$_block" 'should be'
assert_no_match "$_block" 'probably'

# 3.1: ordered BY COMPUTER so this block and the `computers` line agree. Sorting
# on the hex would put mac first on the ASUS (0x0F < 0x11) and pc first on the LG
# (0xD0 < 0xD1) -- the same two computers in opposite orders on two panels,
# purely by which socket each was plugged into.
it 'orders each panel by computer, not by input value'
_asus=$(printf '%s\n' "$TK_OUT" | grep 'asus  *0x')
_lg=$(printf   '%s\n' "$TK_OUT" | grep 'lg  *0x')
assert_match "$_asus" '0x0F -> mac (this one), 0x11 -> pc'
assert_match "$_lg"   '0xD1 -> mac (this one), 0xD0 -> pc'

it 'and the hex order it must NOT use would have reversed the LG'
# Self-test of the case above: proves the assertion could fail. If the LG's two
# values were ordered by input value, pc would come first on that row.
assert_no_match "$_lg" '0xD0 -> pc, 0xD1'

# =============================================================================
# 3.1 an empty map asserts nothing, so the warning would be noise
# =============================================================================

it 'with no display configured, labels the map and omits the warning'
EMPTY="$FAKE_DIR/empty.cfg"
printf 'computer.this = mac\ntrigger.device = usb:046d:0843\n' >"$EMPTY"
run_tk status --config "$EMPTY"
assert_match "$TK_OUT" 'inputs   : none configured'
assert_no_match "$TK_OUT" 'asserted, never verified'
assert_no_match "$TK_OUT" 'Fix: trigger-kvm configure'

# =============================================================================
# 1. it says everything it can, whether or not autostart is installed
# =============================================================================

it 'answers fully on a machine with nothing installed'
run_tk status --config "$CFG"
assert_equal 0 "$TK_RC" "status must not fail on an uninstalled machine: $TK_OUT"
assert_match "$TK_OUT" 'autostart: not installed'
assert_match "$TK_OUT" 'inputs   :'
assert_match "$TK_OUT" 'computers:'

# A panel someone configured and gave no inputs is still a configured panel, and
# saying nothing about it would read as the panel not being there at all.
it 'shows a configured panel that has no inputs, rather than dropping it'
NOIN="$FAKE_DIR/noinput.cfg"
printf 'computer.this = mac\ndisplay.solo.vendor = 0x06B3\ndisplay.solo.product = 0x42E0\n' >"$NOIN"
run_tk status --config "$NOIN"
assert_match "$TK_OUT" 'solo'
assert_match "$TK_OUT" 'no inputs configured'

# config_input_map yields AMBIGUOUS when two inputs on one panel name the same
# computer. That is a file that was edited wrongly, and `pull` refuses on it --
# so status must say which panel, not print a value that looks switchable.
it 'names a panel whose config puts one computer on two inputs'
AMB="$FAKE_DIR/ambiguous.cfg"
printf 'computer.this = mac\ndisplay.dup.vendor = 0x06B3\ndisplay.dup.product = 0x42E0\ndisplay.dup.input.0x0F = mac\ndisplay.dup.input.0x11 = mac\n' >"$AMB"
run_tk status --config "$AMB"
assert_match "$TK_OUT" 'two inputs both name mac'

finish
