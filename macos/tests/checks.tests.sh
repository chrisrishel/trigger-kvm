#!/bin/bash
#
# The two checks -- the only part of this program that deliberately moves a
# monitor while someone is watching.
#
# Driven through the walkthrough's typed fallback, so the real menus, the real
# state and the real config writer are all exercised. Nothing moves: M1DDC
# points at a recorder, so the assertions are about which packets a round WOULD
# have put on the wire and in what order.
#
# The holds are turned down to nothing. Eight seconds is the point on hardware
# and dead weight here.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_setup
fake_displays "$FAKE_LG" "$FAKE_ASUS"
export HOME="$FAKE_DIR/home"; mkdir -p "$HOME"
export TK_TYPED=1 TK_TRIES=1
export TK_HOLD=0 TK_SETTLE_BACK=0 TK_WALK_HOLD=0
# The launcher's directory on PATH, so the "Add to PATH?" row is settled and the
# cursor's recommendation is about the CHECKS rather than about a setting that
# is still open. Where the cursor lands is one of the things under test.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

CFG="$FAKE_DIR/check-config"
LG_UUID=AAAAAAAA-0000-4000-8000-000000000001
ASUS_UUID=BBBBBBBB-0000-4000-8000-000000000002

DELL_UUID=33333333-3333-3333-3333-333333333333

# Three panels, all claiming pc. Batching is only observable here: with two,
# hard rule 4 holds one back and each round has a single panel.
seed_three() {
  fake_displays "$FAKE_LG" "$FAKE_ASUS" "$FAKE_DELL"
  cat > "$CFG" <<'EOS'
computer.this = mac
install.autostart = login
display.asus.vendor  = 0x06B3
display.asus.product = 0x42E0
display.asus.name    = PG42UQ
display.asus.method  = standard
display.asus.input.0x0f = mac
display.asus.input.0x11 = pc
display.dell.vendor  = 0x10AC
display.dell.product = 0xA123
display.dell.name    = U2720Q
display.dell.method  = standard
display.dell.input.0x0f = mac
display.dell.input.0x11 = pc
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.name    = LG ULTRAGEAR+
display.lg.method  = standard
display.lg.input.0x10 = mac
display.lg.input.0x11 = pc
trigger.device   = usb:046d:0843
EOS
}

# A configured two-panel desk, so `configure` opens ready to check.
seed_two() {
  cat > "$CFG" <<'EOS'
computer.this = mac
install.autostart = login
display.asus.vendor  = 0x06B3
display.asus.product = 0x42E0
display.asus.name    = PG42UQ
display.asus.method  = standard
display.asus.input.0x0f = mac
display.asus.input.0x11 = pc
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.name    = LG ULTRAGEAR+
display.lg.method  = standard
display.lg.input.0x10 = mac
display.lg.input.0x11 = pc
trigger.device   = usb:046d:0843
EOS
}

# One panel only, for the single-monitor case.
seed_one() {
  cat > "$CFG" <<'EOS'
computer.this = mac
install.autostart = login
display.asus.vendor  = 0x06B3
display.asus.product = 0x42E0
display.asus.name    = PG42UQ
display.asus.method  = standard
display.asus.input.0x0f = mac
display.asus.input.0x11 = pc
trigger.device   = usb:046d:0843
EOS
}

CK_OUT=''
check_with() {
  printf '%s\n' "$1" > "$FAKE_DIR/answers"
  fake_reset
  set +e
  CK_OUT=$("$TK" configure --config "$CFG" <"$FAKE_DIR/answers" 2>&1)
  set -e
}

# =============================================================================
# batched across panels, never across computers
# =============================================================================

it 'sends several panels to the target TOGETHER, in ONE round'
# Monitors sit side by side, so several are confirmed in one glance; a sequence
# over half a minute has to be held in memory and reported afterwards, and
# memory is the weak link.
seed_three
check_with '7
1

y

y
11'
assert_match "$(fake_sent)" "display $LG_UUID set input 17"
assert_match "$(fake_sent)" "display $ASUS_UUID set input 17"
assert_match "$(fake_sent)" "display $DELL_UUID set input 17"

it 'asks ONCE for the batch, not once per panel'
assert_match "$CK_OUT" 'Did all of them show pc, then come back?'

it 'names the whole batch in one sentence'
assert_match "$CK_OUT" 'Sending LG ULTRAGEAR+ and PG42UQ to pc'

it 'keeps ONE panel on this computer, so the question can be read'
# Hard rule 4. Every panel claims pc, so the last is held back and gets a round
# of its own.
assert_match "$CK_OUT" 'U2720Q stays here, so you can read this'
n=$(printf '%s\n' "$CK_OUT" | grep -c 'Sending ' || true)
assert_equal 2 "$n" 'two rounds: the batch, then the one held back'

it 'says what stays, and what to do about it, EVERY round'
# Told every round rather than asked once: this cannot see where the window is,
# and asking made someone answer a question about the tool's scheduling.
n=$(printf '%s\n' "$CK_OUT" | grep -c 'drag it to' || true)
assert_equal 2 "$n"

it 'brings every panel back to this computer at the end of a round'
assert_match "$(fake_sent)" "display $LG_UUID set input 16"
assert_match "$(fake_sent)" "display $ASUS_UUID set input 15"
assert_match "$(fake_sent)" "display $DELL_UUID set input 15"

it 'reports a pass'
assert_match "$CK_OUT" 'all responded'

it 'a pass sends the cursor onward to the trigger check'
assert_match "$CK_OUT" 'Choice [8]'

it 'with only TWO panels, hard rule 4 still holds one back'
# Batching cannot apply here: holding one back leaves exactly one to move, so
# each round has a single panel and the question is asked in the singular.
seed_two
fake_displays "$FAKE_LG" "$FAKE_ASUS"
check_with '7
1

y

y
11'
assert_match "$CK_OUT" 'Did LG ULTRAGEAR+ show pc, then come back?'
assert_match "$CK_OUT" 'PG42UQ stays here'
n=$(printf '%s\n' "$CK_OUT" | grep -c 'Sending ' || true)
assert_equal 2 "$n"

# =============================================================================
# narrowing only on failure
# =============================================================================

it 'asks which panels failed only when a BATCH is reported bad'
# Only now does anyone have to think. One panel needs no narrowing question,
# which is why this needs three panels to observe at all.
seed_three
check_with '7
1

n
1
3
2
2

y
11'
assert_match "$CK_OUT" 'Which ones did not?'

it 'a failure names the panel IN FULL in the row, and does not read as a pass'
# "LG ULTRAGEAR+" has a space in it, and a space-separated list of failures
# reported two panels called "LG" and "ULTRAGEAR+".
assert_match "$CK_OUT" 'trouble with LG ULTRAGEAR+'
assert_no_match "$CK_OUT" 'LG,ULTRAGEAR'
assert_no_match "$CK_OUT" 'all responded'

it 'a failed check sends the cursor back to Monitors, not onward'
# Where the cursor lands is the recommendation, and after a failure the thing
# to do is fix the setting that failed.
assert_match "$CK_OUT" 'Choice [2]'

# =============================================================================
# the four outcomes, and the manufacturer dialect
# =============================================================================

it 'asks what happened in the order it happened -- did it go, and did it come back'
assert_match "$CK_OUT" 'Did the LG ULTRAGEAR+ change to pc, and back to mac?'
assert_match "$CK_OUT" 'Yes, and it changed back to mac'
assert_match "$CK_OUT" 'Yes, but it did not change back to mac'

it 'only a "no" leads to the second question'
assert_match "$CK_OUT" 'Did the LG ULTRAGEAR+ change at all?'
assert_match "$CK_OUT" 'Yes, but it was not pc'
assert_match "$CK_OUT" 'No, nothing happened'

it 'OFFERS the manufacturer dialect when nothing happened at all'
# Offered, never probed, and only after standard DDC/CI has been shown not to
# work. The values shown are the only ones that will be sent.
assert_match "$CK_OUT" 'did not answer the standard channel'
assert_match "$CK_OUT" 'Yes, try the LG channel'
assert_match "$CK_OUT" 'nothing is guessed at on a manufacturer channel'

it 'shows the documented values before asking'
assert_match "$CK_OUT" 'DisplayPort    0xD0'
assert_match "$CK_OUT" 'USB-C          0xD1'

it 'sends NOTHING on the manufacturer channel when the offer is declined'
assert_no_match "$(fake_sent)" 'input-alt'

it 'offers STANDARD to a panel already on the manufacturer method'
# specs/configure.md 10.5. Since a method can now be chosen up front, a panel
# can reach the check already on the manufacturer one. Telling that person "no
# manufacturer values are known here" would be false, and a dead end.
seed_three
sed -i '' 's/^display.lg.method  = standard/display.lg.method  = lg-alt/' "$CFG"
sed -i '' 's/^display.lg.input.0x10 = mac/display.lg.input.0xD1 = mac/' "$CFG"
sed -i '' 's/^display.lg.input.0x11 = pc/display.lg.input.0xD0 = pc/' "$CFG"
check_with '7
1

n
1
3
2
2

y
11'
assert_match "$CK_OUT" "is on LG's own method and did not answer it"
assert_match "$CK_OUT" 'The standard method'
assert_match "$CK_OUT" 'Yes, try the standard method'

it 'and shows the standard values it would switch to'
assert_match "$CK_OUT" 'DisplayPort 1  0x0F'

it 'never tells a panel that has a documented alternative there is none'
assert_no_match "$CK_OUT" 'no manufacturer values'

it 'does NOT offer a dialect for a vendor that has none'
# A panel absent from the table is offered standard DDC/CI only, because what
# source 0x50 means on an untested panel is unknown. The Dell is the panel held
# back, so its round is the second one and it is checked alone.
seed_three
check_with '7
1

y

n
3
2
11'
assert_match "$CK_OUT" 'no manufacturer values'
assert_match "$CK_OUT" 'are known here for 10AC'
assert_no_match "$CK_OUT" 'Yes, try the'

# =============================================================================
# the single-monitor case
# =============================================================================

it 'warns before taking the ONLY monitor, and says how to get back'
# Being stranded is unavoidable; being stranded WITHOUT having been told how to
# get back is not, and the telling has to happen while there is still a screen
# to read it on.
seed_one
fake_displays "$FAKE_ASUS"
check_with '7
y
y
11'
assert_match "$CK_OUT" 'READ THIS FIRST -- this is your only monitor'
assert_match "$CK_OUT" 'You will not be able to read anything while it is away'
assert_match "$CK_OUT" 'IF IT DOES NOT COME BACK there is nothing this tool can do'
assert_match "$CK_OUT" 'press its input (or source) button'

it "names the input in the MONITOR'S own words, not this tool's"
# The OSD has never heard of "mac".
assert_match "$CK_OUT" 'choose DisplayPort 1, value 0x0F'
assert_no_match "$CK_OUT" 'choose mac'

it 'does not ask which monitor to check when there is only one'
assert_no_match "$CK_OUT" 'Which monitor do you want to check?'

it 'declining reads as NOT CHECKED, never as a pass'
seed_one
check_with '7
n
11'
assert_match "$CK_OUT" 'Skipped. Nothing was sent.'
assert_match "$CK_OUT" 'not checked'
assert_nothing_sent 'declining must send nothing'

it 'and a decline leaves the trigger check unable to pull for real'
assert_no_match "$CK_OUT" 'pulled here for real'

fake_displays "$FAKE_LG" "$FAKE_ASUS"

# =============================================================================
# choosing which monitor to check
# =============================================================================

it 'offers All of them plus each panel by name'
seed_two
check_with '7
q
11'
assert_match "$CK_OUT" 'Which monitor do you want to check?'
assert_match "$CK_OUT" 'All of them'
assert_match "$CK_OUT" 'PG42UQ'
assert_match "$CK_OUT" 'LG ULTRAGEAR+'

it 'backing out of that question checks nothing and sends nothing'
assert_match "$CK_OUT" 'not checked'
assert_nothing_sent

it 'checking ONE panel still keeps the others here'
seed_two
fake_displays "$FAKE_LG" "$FAKE_ASUS"
check_with '7
3

y
11'
# Only the ASUS moves; the LG is never sent anywhere.
assert_match "$(fake_sent)" "$ASUS_UUID"
assert_no_match "$(fake_sent)" "$LG_UUID"
assert_match "$CK_OUT" 'LG ULTRAGEAR+ stays here'

# =============================================================================
# the trigger check
# =============================================================================

it 'moves NOTHING until the inputs have been checked, and says so'
# Before that, a pull would aim unverified values at panels and could leave the
# desk somewhere nobody meant.
seed_two
check_with '8
11'
assert_match "$CK_OUT" 'The arrival will be reported but the monitors will NOT be moved'
assert_nothing_sent 'an unverified trigger check must not pull'
assert_match "$CK_OUT" 'arrival seen'

it 'pulls for REAL once the inputs pass'
seed_two
fake_displays "$FAKE_LG" "$FAKE_ASUS"
check_with '7
1

y

y
8
y
11'
assert_match "$CK_OUT" 'the monitors will be pulled here for real'
assert_match "$CK_OUT" 'Pulling the monitors here'
assert_match "$CK_OUT" 'fired, monitors followed'

it 'a pull that does not land is a MONITORS fault, not a trigger fault'
seed_two
fake_displays "$FAKE_LG" "$FAKE_ASUS"
check_with '7
1

y

y
8
n
11'
assert_match "$CK_OUT" 'The trigger fired, so the devices are right'
assert_match "$CK_OUT" 'fired, but the monitors did not follow'

it 'no arrival is reported as such, and points back at Triggers'
seed_two
TK_FAKE_TRIGGER_RC=1 check_with '8
11'
assert_match "$CK_OUT" 'Nothing arrived'
assert_match "$CK_OUT" 'no arrival seen'

it 'refuses to check a trigger before any device is chosen'
cat > "$CFG" <<'EOS'
computer.this = mac
install.autostart = login
display.asus.vendor  = 0x06B3
display.asus.product = 0x42E0
display.asus.method  = standard
display.asus.input.0x0f = mac
EOS
check_with '8
11'
assert_match "$CK_OUT" 'No trigger devices are chosen yet'

# =============================================================================
# the installed watcher during the trigger check (specs 11)
# =============================================================================

it 'stands the login-tier watcher down for the check, and restores it after'
# On a re-run the installed watcher sees the same flip and pulls against the
# SAVED config after the one-shot's pull, so a correct new answer reads as the
# monitors failing.
seed_two
: >"$TK_PLIST"
rm -f "$TK_DAEMON_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
check_with '8
11'
assert_match "$CK_OUT" 'The running watcher is paused for this check.'
log=$(cat "$TK_FAKE_LAUNCHCTL")
assert_match "$log" 'bootout gui/'   'stood down before the flip'
assert_match "$log" 'bootstrap gui/' 'and restored after'
# tk_bootstrap does its OWN bootout before every load, so "a bootout appears"
# stopped proving the check stood the watcher down -- the reload alone puts one
# in the log. What proves it is a SECOND bootout: the stand-down, before the
# seam's reload pair. Removing the stand-down leaves exactly one, and this is
# the assertion that notices.
assert_true "$([ "$(printf '%s\n' "$log" | grep -c 'bootout gui/')" -ge 2 ] && echo 0 || echo 1)" \
  "only the seam's own bootout is here; the stand-down is missing: $log"
assert_true "$([ "$(printf '%s\n' "$log" | grep -n bootout | cut -d: -f1 | head -1)" -lt \
                "$(printf '%s\n' "$log" | grep -n bootstrap | cut -d: -f1 | head -1)" ] && echo 0 || echo 1)" \
  "bootout must come before bootstrap: $log"

it 'and says so LOUDLY when the watcher it paused could not be restarted'
# This check stands the watcher down on purpose. A failed restore therefore
# leaves the machine with nothing watching, caused by the check itself -- the
# one outcome that must never be silent. It was `|| true`.
seed_two
: >"$TK_PLIST"
rm -f "$TK_DAEMON_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
TK_FAKE_LAUNCHCTL_FAIL=bootstrap check_with '8
11'
assert_match "$CK_OUT" 'could not restart the watcher this check paused'
assert_match "$CK_OUT" 'NOTHING IS WATCHING until you run:  trigger-kvm restart'

it 'says so when the boot-tier watcher is left running, rather than asking for a password'
rm -f "$TK_PLIST"
: >"$TK_DAEMON_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
check_with '8
11'
assert_match "$CK_OUT" 'The running watcher will also fire, using the saved configuration.'
assert_no_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootout' 'the system domain needs a password; leave it'
rm -f "$TK_DAEMON_PLIST"

# =============================================================================
# backing out of a check is not a failure (specs 4.2)
# =============================================================================

it 'backing out of the scope question reads not checked, and the cursor moves on'
# Landing on Monitors said "you got the monitors wrong" to someone who only
# declined to move them.
seed_two
fake_displays "$FAKE_LG" "$FAKE_ASUS"
check_with '7
q
11'
assert_match "$CK_OUT" 'Test the monitor inputs      not checked'
assert_match "$CK_OUT" 'Choice [8]' 'the cursor goes on to the trigger check, not back to Monitors'

finish
