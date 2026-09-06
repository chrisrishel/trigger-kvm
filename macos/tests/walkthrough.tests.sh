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
6
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

it 'stores the transport it used, without ever asking about it'
# specs/configure.md 6.3: a platform with one transport asks nothing and stores
# the transport it used. So the file says what the panel was verified with --
# which is the whole reason the key exists -- while the walkthrough gains no
# menu, because there is nothing to choose between.
assert_match "$c" 'display.lg.transport = ioavservice'
assert_match "$c" 'display.asus.transport = ioavservice'
assert_no_match "$WT_OUT" 'transport'
assert_no_match "$WT_OUT" 'how the bytes get there'

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

it 'names the consequence where the method is chosen'
# specs/configure.md 6.2: this is the moment a person commits to a service
# channel, and the rules that keep it safe live in a file they never open.
assert_match "$WT_OUT" "LG's own method talks to a service channel on the monitor. It is"
assert_match "$WT_OUT" 'sent only the values written down for it: unknown values on that'
assert_match "$WT_OUT" 'channel have made monitors unusable.'

it 'choosing it up front writes that method, with no check having run'
# The whole point: the documented values are reachable without failing first.
# Written out rather than derived from $FULL -- the two scripts diverge at the
# method question and stay diverged, because the input tables differ from there.
ALT='1
mac

pc
6
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

it 'warns before a value is typed onto a manufacturer channel'
# specs/configure.md 6.1: a typed byte is the one thing that reaches the service
# channel from outside the documented table.
rm -f "$CFG"
PATH=$SAVED_PATH configure_with '1
mac

pc
6
2
1


2
5
0xD1
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
assert_match "$WT_OUT" "This is the manufacturer's service channel. Type only a value you have"
assert_match "$WT_OUT" 'from documentation; an unknown value here has made monitors unusable.'
assert_match "$(cat "$CFG")" 'display.lg.input.0xd1 = mac' "$WT_OUT"

it 'and does not say it on the standard channel'
# The standard channel is not the service channel; the warning would be noise.
PATH=$SAVED_PATH configure_with "$FULL"
assert_no_match "$WT_OUT" "This is the manufacturer's service channel"

# =============================================================================
# a panel's questions are one submenu (specs 6)
# =============================================================================

it 'esc at the method question backs out of the panel, leaving it as it was'
# It used to keep the current method and PROCEED to the input questions, with
# no key that went back until every computer was answered.
rm -f "$CFG"
PATH=$SAVED_PATH configure_with '1
mac

pc
6
2
1


q
4
11'
assert_no_match "$WT_OUT" "On the LG ULTRAGEAR+, which input is" 'esc must not advance to the inputs'
n=$(printf '%s\n' "$WT_OUT" | grep -c 'LG ULTRAGEAR+ *not managed' || true)
assert_equal 2 "$n" "the list is shown again with the LG still not managed: $WT_OUT"
assert_true "$([ ! -f "$CFG" ] && echo 0 || echo 1)" 'Cancel: nothing written'

it 'esc at an input question backs out of the panel too'
rm -f "$CFG"
PATH=$SAVED_PATH configure_with '1
mac

pc
6
2
1



q
4
11'
n=$(printf '%s\n' "$WT_OUT" | grep -c 'LG ULTRAGEAR+ *not managed' || true)
assert_equal 2 "$n" "half a map is not an answer; the panel stays as it was: $WT_OUT"

# =============================================================================
# the short name is unique; typed values collide by value (specs 6, 6.1)
# =============================================================================

it 'refuses a short name another monitor already has, and asks again'
# Two panels with one label would be written as one and read back as a merge of
# both, and the switcher would refuse without saying why.
rm -f "$CFG"
PATH=$SAVED_PATH configure_with '1
mac

pc
6
2
1



9
0xD1
10
0xD0
2

lg
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
assert_match "$WT_OUT" 'There is already a monitor called lg'
assert_match "$(cat "$CFG")" 'display.asus.vendor  = 0x06B3' "$WT_OUT"

it 'refuses a typed value that names an assigned input under another spelling'
# 17 and 0x11 are one socket. Both were accepted as two, and the switcher then
# sent the same byte for both computers.
rm -f "$CFG"
PATH=$SAVED_PATH configure_with '1
mac

pc
6
2
1



9
0xD1
10
0xD0
2

asus
3
9
17
9
15
4
3
1,2
4
2
5
2
10'
assert_match "$WT_OUT" '0x11 is already mac on this monitor. Two computers cannot share one input.'

it 'and stores a typed value in the canonical 0xNN spelling'
c2=$(cat "$CFG")
assert_match "$c2" 'display.asus.input.0x0f = pc' "$WT_OUT"
assert_no_match "$c2" 'input.15'

# =============================================================================
# every key the walkthrough does not write is carried across (config-format)
# =============================================================================

it 'keeps a hand-edited key it has never heard of, and a managed panel'"'"'s extra key'
# A key the reader does not know is someone's hand edit or a newer version's
# setting; dropping it on Save is a loss nobody notices. A key of a panel that
# was UNMANAGED goes, because that answer means forget the panel.
cat >"$CFG" <<'EOS'
computer.this = mac
trigger.hotkey = f13
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.serial  = 0009
display.old.vendor = 0x0001
display.old.note   = gone
trigger.device = usb:046d:0843
trigger.debounce = 4.5
EOS
PATH=$SAVED_PATH configure_with "$FULL"
c3=$(cat "$CFG")
assert_match "$c3" 'trigger.hotkey = f13'  "$WT_OUT"
assert_match "$c3" 'display.lg.serial = 0009' 'a managed panel keeps its extra key'
assert_match "$c3" 'trigger.debounce = 4.5' 'the timings still carry'
assert_no_match "$c3" 'display.old' 'an unmanaged panel is forgotten whole'

# =============================================================================
# an account that cannot elevate is not offered From boot (specs 8)
# =============================================================================

it 'draws From boot disabled, with the reason, for an account that is not an administrator'
mkdir -p "$FAKE_DIR/nonadmin"
cat >"$FAKE_DIR/nonadmin/id" <<'EOS'
#!/bin/sh
case "$1" in -Gn) echo 'staff everyone' ;; *) exec /usr/bin/id "$@" ;; esac
EOS
chmod +x "$FAKE_DIR/nonadmin/id"
rm -f "$CFG"
PATH="$FAKE_DIR/nonadmin:$SAVED_PATH" configure_with "$FULL"
assert_match "$WT_OUT" 'needs an administrator account'
assert_match "$WT_OUT" '-- From boot' 'the row is drawn but cannot be chosen'
assert_match "$(cat "$CFG")" 'install.autostart = login' "$WT_OUT"

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

it 'declining the password falls back to login, and says so'
# Written out rather than derived from $FULL: deriving it needs to find "the
# answer after the one that says 4", which is exactly the kind of cleverness
# that has already produced two wrong test scripts here.
BOOT='1
mac

pc
6
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
# Declining the password must FALL BACK to login and say so -- and it rewrites
# the config, because the config has to record what actually happened rather
# than what was asked for. Silently keeping "boot" is how someone finds out
# months later that switching does nothing until they log in.
mkdir -p "$FAKE_DIR/nosudo"
cat >"$FAKE_DIR/nosudo/sudo" <<'EOS'
#!/bin/sh
exit 1
EOS
chmod +x "$FAKE_DIR/nosudo/sudo"
rm -f "$CFG"
PATH="$FAKE_DIR/nosudo:$SAVED_PATH" configure_with "$BOOT"
assert_match "$WT_OUT" 'falling back to starting at login'
assert_match "$(cat "$CFG")" 'install.autostart = login' \
  'the config must record what happened, not what was asked for'

it 'choosing boot APPLIES it, rather than only recording it'
# THE BUG THIS EXISTS FOR: configure wrote install.autostart = boot and then
# exec'd `restart`, which only bounces the LaunchAgent. The daemon was never
# installed and the password was never even asked for, so the tier silently did
# nothing while the config claimed it was on. A test that the config was WRITTEN
# did not catch it; only a test that it was APPLIED does.
#
# sudo is the harness stub, which runs the command unprivileged. launchctl needs
# no stub of its own: the harness already points $TK_LAUNCHCTL at a recorder for
# the whole suite, and what it was asked is read back from $TK_FAKE_LAUNCHCTL.
fake_sudo_stub
: >"$TK_FAKE_LAUNCHCTL"
rm -f "$TK_DAEMON_PLIST" "$CFG"
PATH="$FAKE_DIR/bin:$SAVED_PATH" configure_with "$BOOT"

assert_match "$(cat "$CFG")" 'install.autostart = boot' "$WT_OUT"
assert_true "$([ -f "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" \
  "the LaunchDaemon must actually be installed: $WT_OUT"

it 'and removes the LaunchAgent, so both tiers cannot start at the next login'
# A launchd label is per DOMAIN. Booting the agent out covers this session only;
# the file left in ~/Library/LaunchAgents would start it again at login, beside
# the daemon, where it loses the lock and respawns every ten seconds forever.
assert_true "$([ ! -f "$TK_PLIST" ] && echo 0 || echo 1)" 'the LaunchAgent plist must be removed'

it 'and the daemon it writes runs as the USER, not as root'
# UserName is the whole property. Without it this is a root daemon acting on a
# user-writable config, which is a local privilege escalation.
d=$(cat "$TK_DAEMON_PLIST" 2>/dev/null)
assert_match "$d" '<key>UserName</key>'
assert_match "$d" "<string>$(id -un)</string>"
assert_no_match "$d" '<string>root</string>'

it 'and loads it into the SYSTEM domain, not the user one'
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap system'

it 'and says the password is only for installing'
assert_match "$WT_OUT" 'needs your password once, to install it'
assert_match "$WT_OUT" 'Nothing runs as an administrator afterwards'

it 'choosing login afterwards removes the boot daemon'
# Mutually exclusive: two live watchers would both fire on the same arrival,
# and the debounce is per-process.
: >"$TK_FAKE_LAUNCHCTL"
rm -f "$CFG"
PATH="$FAKE_DIR/bin:$SAVED_PATH" configure_with "$FULL"
assert_true "$([ ! -f "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" 'the daemon must be removed'
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap gui/'
assert_true "$([ -f "$TK_PLIST" ] && echo 0 || echo 1)" 'and the LaunchAgent written back'

rm -f "$CFG"
PATH=$SAVED_PATH configure_with "$FULL"

it 'ends by saying what to do next, from configure as well as from the installer'
# The closing words lived in install.sh only, so a first install (which hands
# off to configure) and every later configure ended at "loaded the LaunchAgent".
assert_match "$WT_OUT" 'Flip your switch to this computer -- the monitors should follow.'
assert_match "$WT_OUT" 'status      is it running?'

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

# =============================================================================
# enter never destroys (specs/configure.md 5.0, 5.3, 6)
# =============================================================================

# Three computers, with the third on one panel only -- so the remove list has
# two different costs to state, and so a rename and a removal in one sitting
# shift the list, which is the case that inferring the edits afterwards got
# wrong. Every scripted run below ends on Save, and asserts that the save
# happened: a run that dies early leaves the seed in place, and a seed that
# still holds the name proves nothing about what kept it there.
seed_three() {
  cat >"$CFG" <<'EOS'
computer.this = mac
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.name    = LG ULTRAGEAR+
display.lg.method  = standard
display.lg.input.0xD1 = mac
display.lg.input.0xD0 = pc
display.lg.input.0xD2 = linux
display.asus.vendor  = 0x06B3
display.asus.product = 0x42E0
display.asus.name    = PG42UQ
display.asus.method  = standard
display.asus.input.0x0F = mac
display.asus.input.0x11 = pc
trigger.device   = usb:046d:0843, usb:1235:820a
install.autostart = login
EOS
}

it 'a saved config never defines a key twice, however the previous one was written'
# Every key the walkthrough writes itself must be excluded from the carry-through
# block, or Save emits it a second time under "kept from the previous file". The
# reader lets the last one win, so the file still BEHAVES correctly -- which is
# exactly why this needs asserting rather than noticing. A duplicate definition
# is the shape specs/README.md warns about: present, and the one you are reading
# is not the one in force.
seed_three
# Seeded with the keys a previous version wrote, including the one added most
# recently -- the case where the exclusion list is a step behind the writer.
{ printf 'display.lg.transport = ioavservice\n'
  printf 'display.asus.transport = ioavservice\n'; } >>"$CFG"
configure_with '10'
assert_match "$WT_OUT" 'wrote'
dupes=$(grep -E '^[A-Za-z0-9_.-]+[[:space:]]*=' "$CFG" |
        sed 's/[[:space:]]*=.*//' | tr -d ' ' | sort | uniq -d)
assert_equal '' "$dupes" 'these keys are defined more than once'

it 'a blank answer at the rename prompt KEEPS the name'
# It used to remove the computer -- the most innocuous keypress there is was
# the destructive one. The prompt is pre-filled like every other prompt here.
seed_three
configure_with '1
2

7
10'
assert_match "$WT_OUT" "New name for 'pc' [pc]"
assert_match "$WT_OUT" 'wrote'
c=$(cat "$CFG")
assert_match "$c" 'display.lg.input.0xd0 = pc'
assert_match "$c" 'display.asus.input.0x11 = pc'
assert_match "$c" 'display.lg.input.0xd2 = linux'

it 'removing a computer is a ROW, and it says what each removal costs'
configure_with '1
6
4
7
11'
assert_match "$WT_OUT" '--- remove a computer ---'
assert_match "$WT_OUT" 'Removing a computer also clears its input on every monitor it is on.'
assert_match "$WT_OUT" '1) pc                           on lg and asus'
assert_match "$WT_OUT" '2) linux                        on lg'

it 'and this computer is not on it'
# Its name is what `pull` resolves; a config without it is one the switcher
# declines to act on.
blk=$(printf '%s\n' "$WT_OUT" | sed -n '/--- remove a computer ---/,/Choice/p')
assert_no_match "$blk" 'mac'

it 'the removal is confirmed, and the default is NO'
configure_with '1
6
1

4
7
10'
assert_match "$WT_OUT" 'Its input on every monitor is cleared too. Nothing else changes.'
assert_match "$WT_OUT" "Remove 'pc'? [y/N]"
assert_match "$WT_OUT" 'wrote'
c=$(cat "$CFG")
assert_match "$c" 'display.lg.input.0xd0 = pc'
assert_match "$c" 'display.asus.input.0x11 = pc'

it 'yes removes it, and clears its input on every monitor'
configure_with '1
6
1
y
3
6
10'
assert_match "$WT_OUT" 'wrote'
assert_match "$WT_OUT" 'mac (this), linux'
c=$(cat "$CFG")
assert_no_match "$c" '= pc'
assert_match "$c" 'display.lg.input.0xd1 = mac'
assert_match "$c" 'display.lg.input.0xd2 = linux'
assert_match "$c" 'display.asus.input.0x0f = mac'

it 'a rename and a removal in one sitting each land on the right computer'
# Rename linux to box, THEN remove pc. Lining the old list [pc linux] up
# against the new one [box] afterwards read that as "pc renamed to box, linux
# removed" -- the removal shifted every position after it. Edits are applied
# as they happen instead.
seed_three
configure_with '1
3
box
6
1
y
3
6
10'
assert_match "$WT_OUT" 'wrote'
c=$(cat "$CFG")
assert_match "$c" 'display.lg.input.0xd2 = box'
assert_no_match "$c" 'linux'
assert_no_match "$c" '= pc'

it 'the Remove row is drawn but disabled once there is nobody to remove'
cat >"$CFG" <<'EOS'
computer.this = mac
display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.input.0xD1 = mac
trigger.device   = usb:046d:0843
install.autostart = login
EOS
configure_with '1
5
11'
assert_match "$WT_OUT" '   -- Remove a computer'
assert_match "$WT_OUT" 'cancelled; nothing was changed'

it 'answering no to "Manage this monitor?" confirms when there is something to lose'
# "Manage" reads like a flag; the answer forgets which computer is on which
# input. Same rule as removing a computer: say what is discarded, and ask.
seed_three
configure_with '2
1
n

4
10'
assert_match "$WT_OUT" 'Which computer is on which of its inputs is forgotten. Nothing else'
assert_match "$WT_OUT" 'Stop managing this monitor? [y/N]'
assert_match "$WT_OUT" 'wrote'
c=$(cat "$CFG")
assert_match "$c" 'display.lg.input.0xd0 = pc'
assert_match "$c" 'display.lg.vendor  = 0x1E6D'

it 'yes stops managing it, and forgets its inputs'
configure_with '2
1
n
y
4
10'
assert_match "$WT_OUT" 'wrote'
c=$(cat "$CFG")
assert_no_match "$c" 'display.lg.'
assert_match "$c" 'display.asus.input.0x11 = pc'

it 'a panel with nothing to lose is not asked twice'
# The LG is unmanaged now. Were it asked, "4" would be a refused yes/no answer
# and the run would hit EOF instead of reaching Cancel.
configure_with '2
1
n
4
11'
assert_no_match "$WT_OUT" 'Stop managing this monitor?'
assert_match "$WT_OUT" 'cancelled; nothing was changed'

finish
