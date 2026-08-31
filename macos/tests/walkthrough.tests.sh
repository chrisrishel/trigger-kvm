#!/bin/bash
#
# The walkthrough, driven end to end through the TYPED FALLBACK.
#
# That is what the fallback is for. Every prompt and every menu reads a line
# from stdin when the host cannot read individual keys, so a complete script of
# answers exercises the real flow -- the real menus, the real state, the real
# config writer -- with nothing stubbed but the hardware.
#
# Nothing here can move a monitor: M1DDC points at a recorder, and the checks
# are covered separately in checks.tests.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_setup
fake_displays "$FAKE_LG" "$FAKE_ASUS"

# A HOME of our own, so ~/.local/bin is reliably NOT on PATH and the "Add to
# PATH?" row is a live question rather than a disabled one. The disabled case
# gets its own test below.
export HOME="$FAKE_DIR/home"
mkdir -p "$HOME"
export TK_TYPED=1 TK_TRIES=1

CFG="$FAKE_DIR/wt-config"
SAVED_PATH=$PATH

# Answer the walkthrough. Everything after the first argument is one answer per
# line; running out of them makes configure stop and say so, which is what turns
# a flow change into a failed test instead of a hung run.
WT_OUT=''
WT_RC=0
configure_with() {
  _answers=$1; shift
  printf '%s\n' "$_answers" > "$FAKE_DIR/answers"
  set +e
  WT_OUT=$("$TK" configure --config "$CFG" "$@" <"$FAKE_DIR/answers" 2>&1)
  WT_RC=$?
  set -e
}

# The full script for a fresh desk: two computers, two panels, two triggers.
FULL='1
mac

pc
5
2
1



9
0xD1
10
0xD0
2

asus
1
3
4
3
1,2
4
2
5
2
10'

# =============================================================================
# from nothing, the menu alone produces a config
# =============================================================================

rm -f "$CFG"
configure_with "$FULL"

it 'the menu IS the flow -- an empty install is the same menu with "not set" in it'
assert_match "$WT_OUT" 'Computers                    not set'
assert_match "$WT_OUT" 'Monitors                     not set'
assert_match "$WT_OUT" 'Triggers                     not set'
assert_match "$WT_OUT" 'Autostart?                   not set'
assert_match "$WT_OUT" 'Add to PATH?                 not set'

it 'the checks are shown as untested, not as passed'
assert_match "$WT_OUT" 'Test the monitor inputs      untested'
assert_match "$WT_OUT" 'Test the triggers            untested'

it 'the header says configuration until monitors and triggers are set'
assert_match "$WT_OUT" '--- configuration ---'

it 'writes a config'
assert_true "$([ -f "$CFG" ] && echo 0 || echo 1)" "$WT_OUT"

it 'names this computer and the other one'
assert_match "$(cat "$CFG")" 'computer.this = mac'

it 'writes both panels with the EDID ids read off the hardware'
c=$(cat "$CFG")
assert_match "$c" 'display.lg.vendor  = 0x1E6D'
assert_match "$c" 'display.lg.product = 0x9E9F'
assert_match "$c" 'display.asus.vendor  = 0x06B3'
assert_match "$c" 'display.asus.product = 0x42E0'

it "writes each panel's own name, from the EDID"
assert_match "$c" 'display.lg.name    = LG ULTRAGEAR+'
assert_match "$c" 'display.asus.name    = PG42UQ'

it 'defaults every panel to standard, whatever the make'
# Standard is the default and the cursor starts there; the script above takes it
# by answering blank. A manufacturer method is never chosen FOR someone.
assert_match "$c" 'display.lg.method  = standard'
assert_match "$c" 'display.asus.method  = standard'

it "offers the manufacturer's method up front for a vendor that has one"
# specs/configure.md 6.2. Someone who already knows their model needs it should
# not have to run a check that moves a panel purely in order to fail.
assert_match "$WT_OUT" '--- how to talk to this monitor ---'
assert_match "$WT_OUT" "LG's own method"
assert_match "$WT_OUT" 'for LG models that ignore the standard one'

it 'and does NOT offer it for a vendor that has none'
# Keyed by vendor, never by model, from the one table the check escalates to.
n=$(printf '%s\n' "$WT_OUT" | grep -c 'how to talk to this monitor' || true)
assert_equal 1 "$n" 'only the LG should be asked; the ASUS has no documented alternative'

it 'choosing it up front writes that method, with no check having run'
# The whole point: the documented values are reachable without failing first.
# Written out rather than derived from $FULL -- the two scripts diverge at the
# method question and stay diverged, because the input tables differ from there.
ALT='1
mac

pc
5
2
1


2
2
1
2

asus
1
3
4
3
1,2
4
2
5
2
10'
rm -f "$CFG"
PATH=$SAVED_PATH configure_with "$ALT"
assert_match "$(cat "$CFG")" 'display.lg.method  = lg-alt' "$WT_OUT"

it "and offers that method's OWN documented values, not the standard ones"
assert_match "$WT_OUT" '0xD1'
assert_match "$WT_OUT" '0xD0'

it 'so the map it writes uses them'
assert_match "$(cat "$CFG")" 'display.lg.input.0xd1 = mac'
assert_match "$(cat "$CFG")" 'display.lg.input.0xd0 = pc'

it 'the values it offers come from the documented table, never from a probe'
# AGENTS.md hard rule 1b: OFFERED, never probed. Nothing is sent while asking.
assert_nothing_sent 'choosing a method must not touch a monitor'

rm -f "$CFG"
PATH=$SAVED_PATH configure_with "$FULL"

it 'writes the input map, and only the input map'
assert_match "$c" 'display.lg.input.0xd1 = mac'
assert_match "$c" 'display.lg.input.0xd0 = pc'
assert_match "$c" 'display.asus.input.0x0f = mac'
assert_match "$c" 'display.asus.input.0x11 = pc'
assert_no_match "$c" 'display.lg.self'
assert_no_match "$c" 'scene.'

it 'writes the triggers it was given'
assert_match "$c" 'trigger.device   = usb:046d:0843, usb:1235:820a'

it 'writes the timings, with the shipped defaults'
assert_match "$c" 'trigger.debounce = 3.0'
assert_match "$c" 'trigger.settle   = 0.75'

it 'writes the autostart answer'
assert_match "$c" 'install.autostart = login'

it 'offers the boot tier FIRST, and as a real choice'
# specs/configure.md 8. It was drawn-and-disabled for a while on the claim that
# a LaunchDaemon must run as root -- one with UserName set runs as the user, and
# root is needed only to install it.
assert_match "$WT_OUT" 'From boot'
assert_no_match "$WT_OUT" 'not available on macOS'
assert_no_match "$WT_OUT" '   -- From boot'

it 'says what the boot tier actually costs'
assert_match "$WT_OUT" 'needs your password once, to install'
assert_match "$WT_OUT" 'Nothing runs as an administrator afterwards'

it 'and choosing it writes boot'
# Written out rather than derived from $FULL: deriving it needs to find "the
# answer after the one that says 4", which is exactly the kind of cleverness
# that has already produced two wrong test scripts here.
BOOT='1
mac

pc
5
2
1



9
0xD1
10
0xD0
2

asus
1
3
4
3
1,2
4
1
5
2
10'
rm -f "$CFG"
PATH=$SAVED_PATH configure_with "$BOOT"
assert_match "$(cat "$CFG")" 'install.autostart = boot' "$WT_OUT"

rm -f "$CFG"
PATH=$SAVED_PATH configure_with "$FULL"

it 'the config it wrote is one the switcher accepts'
# The real test of "identical in shape": pull resolves against it and sends.
fake_reset
run_tk pull --config "$CFG"
assert_equal 0 "$TK_RC" "$TK_OUT"
assert_match "$(fake_sent)" 'set input 15'
assert_match "$(fake_sent)" 'set input 209'

it 'moved nothing while being configured'
# The walkthrough writes a config; it does not switch anything until asked.
assert_no_match "$WT_OUT" 'DRY RUN'

# =============================================================================
# a re-run opens with nothing to fill in
# =============================================================================

# With the launcher's directory already on PATH -- the state a real install
# leaves behind -- there is genuinely nothing left to fill in. PATH is not a
# config value and is deliberately re-asked each run when it is still an open
# question; that case has its own test below.
export PATH="$HOME/.local/bin:$PATH"

it 'a re-run opens with every answer already in it'
configure_with '11'          # straight to Cancel
assert_no_match "$WT_OUT" 'not set'
assert_match "$WT_OUT" 'mac (this), pc'
assert_match "$WT_OUT" 'lg: mac/pc'
assert_match "$WT_OUT" 'asus: mac/pc'
assert_match "$WT_OUT" 'usb:046d:0843, usb:1235:820a'
assert_match "$WT_OUT" 'from login'

it 'the header says REVIEW once monitors and triggers are set'
assert_match "$WT_OUT" '--- review configuration ---'

it 'the cursor lands on the first CHECK once every setting is answered'
# Where the cursor lands is the recommendation, and it is "the next thing that
# is not done": the unanswered sections in order, THEN the checks in order,
# then Save. Nothing has been checked yet, so it lands there and not on Save.
assert_match "$WT_OUT" 'Choice [7]'

it 'esc on the top menu moves to Cancel, and does not discard on its own'
# specs/configure.md 3.3. In the typed fallback "moving the cursor" is making it
# the default, so this is still two keystrokes: q, then enter.
configure_with 'q
'
assert_equal 1 "$WT_RC"
assert_match "$WT_OUT" 'cancelled; nothing was changed'

it 'Cancel changes nothing'
before=$(cat "$CFG")
configure_with '11'
assert_equal 1 "$WT_RC"
assert_match "$WT_OUT" 'cancelled; nothing was changed'
assert_equal "$before" "$(cat "$CFG")"

# =============================================================================
# --fresh asks everything again
# =============================================================================

it '--fresh pre-fills nothing, even with a config present'
configure_with '11' --fresh
assert_match "$WT_OUT" 'Starting fresh'
assert_match "$WT_OUT" 'Computers                    not set'
assert_match "$WT_OUT" 'Monitors                     not set'
assert_match "$WT_OUT" 'Triggers                     not set'

it '--fresh still leaves the existing config alone when cancelled'
before=$(cat "$CFG")
configure_with '11' --fresh
assert_equal "$before" "$(cat "$CFG")"

# =============================================================================
# save refuses while a section is unset
# =============================================================================

it 'Save REFUSES while a required section is not set, and names what is missing'
# Writing half a setup produces a config the switcher then declines to act on,
# which is a worse way to find out.
rm -f "$CFG"
configure_with '10
11'
assert_match "$WT_OUT" 'Still needed:'
assert_match "$WT_OUT" 'Computers'
assert_match "$WT_OUT" 'Monitors'
assert_match "$WT_OUT" 'Triggers'
assert_true "$([ ! -f "$CFG" ] && echo 0 || echo 1)" 'nothing may be written'

it 'the checks are NOT required to save'
# They move hardware, and someone may reasonably decline. Only the five
# settings are required. Run with the original PATH, because $FULL answers the
# PATH row and that row is disabled once the directory is on PATH -- which is
# exactly the shape-change a scripted run would trip over.
rm -f "$CFG"
PATH=$SAVED_PATH configure_with "$FULL"
assert_true "$([ -f "$CFG" ] && echo 0 || echo 1)" "$WT_OUT"

it 'nothing is written until Save -- an interrupted run leaves the config alone'
PATH=$SAVED_PATH configure_with "$FULL"
before=$(cat "$CFG")
set +e
printf '1\nrenamed\n' | "$TK" configure --config "$CFG" >/dev/null 2>&1
set -e
assert_equal "$before" "$(cat "$CFG")" 'an aborted run must not write'

# =============================================================================
# the PATH row is always drawn
# =============================================================================

it 'the PATH row is drawn and DISABLED when there is nothing to decide'
# Omitting it moved every row below it and left the cursor apparently skipping
# a step, with no way to tell whether PATH had been handled or forgotten.
configure_with '11'
assert_match "$WT_OUT" 'Add to PATH?'
assert_match "$WT_OUT" 'already on PATH'
assert_match "$WT_OUT" '   -- Add to PATH?' 'drawn, and unpickable'

it 'and it is still a live question when the directory is NOT on PATH'
PATH=$SAVED_PATH configure_with '11'
assert_match "$WT_OUT" 'Add to PATH?                 not set'
assert_no_match "$WT_OUT" '   -- Add to PATH?'

finish
