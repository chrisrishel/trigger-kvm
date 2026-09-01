#!/bin/bash
#
# The watcher: its candidate list, its single-instance lock, its log rotation
# and its one-shot mode.
#
# These run the real binary against the real machine, because that is what they
# are about -- but they cannot move a monitor, because --exec points at
# /bin/echo throughout. The watcher never touches a display itself; it spawns
# the switcher, and here the switcher is echo.
#
# They assert PROPERTIES of what the machine reports, never a particular
# device: which devices are attached is this machine's business, and a suite
# that named one described a single desk and went red on every other. The one
# thing a few cases need -- a device that is present right now -- is taken
# from the watcher's own list, and those cases SKIP, saying so, on a machine
# with nothing attached.
#
# HOME is redirected at a temp directory so the lock file under
# "Library/Application Support/trigger-kvm" is a fresh one and a real installed
# watcher, if any, is neither seen nor disturbed.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$MAC_DIR/event-watch"
if [ ! -x "$WATCH" ]; then
  echo "event-watch is not built; run: make" >&2
  exit 1
fi

fake_setup
export HOME="$FAKE_DIR/home"
mkdir -p "$HOME/Library/Application Support/trigger-kvm"
LOG="$FAKE_DIR/watch.log"

# A device that cannot be attached. Its present counterpart is derived from
# the live list below, once there is one.
ABSENT=usb:dead:beef
PRESENT=""

# The cases that need a present device skip, visibly, when there is none.
skip_no_present() { echo "  SKIP  $CASE -- no USB device is attached to stand in as present" >&2; }

kill_watchers() { pkill -f "$WATCH" 2>/dev/null || true; sleep 0.3; }
trap 'kill_watchers' EXIT

# Background a watcher and disown it, so bash does not print "Terminated" over
# the test output when it is later killed. A real failure should be the only
# noise in here.
# stderr goes INTO the log, which is what the LaunchAgent does with
# StandardErrorPath. The watcher writes only to stderr; --log tells it which
# file that is, so it knows what to rotate.
bg_watch() {
  "$WATCH" --exec /bin/echo --arg TEST "$@" >>"$LOG" 2>&1 &
  disown 2>/dev/null || true
  sleep 1
}

# Run something that is SUPPOSED to exit promptly, and fail rather than hang if
# it does not. Every "a redundant start stands down" assertion below depends on
# the program returning; without a bound, a watcher that wrongly keeps the lock
# open turns a failing test into a wedged suite -- which is how the mutation run
# for these was first lost. macOS has no timeout(1), hence the watchdog.
BOUNDED_OUT=""; BOUNDED_RC=0
run_bounded() {
  _secs=$1; shift
  _f="$FAKE_DIR/bounded.out"; : >"$_f"
  "$@" >"$_f" 2>&1 &
  _pid=$!
  ( sleep "$_secs"; kill -9 "$_pid" 2>/dev/null ) >/dev/null 2>&1 &
  _wd=$!
  disown 2>/dev/null || true
  set +e; wait "$_pid"; BOUNDED_RC=$?; set -e
  kill "$_wd" 2>/dev/null || true
  BOUNDED_OUT=$(cat "$_f")
}

# =============================================================================
# --list: what could be a trigger
# =============================================================================

LIST=$("$WATCH" --list)

it 'lists candidates as kind|key|state|name'
bad=$(printf '%s\n' "$LIST" | grep -vc '^\(usb\|bt\)|[a-z]*:[0-9a-f:]*|[^|]*|' || true)
assert_equal 0 "$bad" "malformed rows in: $LIST"

it 'a USB row is always "attached now" -- USB has no paired-but-absent state'
bad=$(printf '%s\n' "$LIST" | awk -F'|' '$1 == "usb" && $3 != "attached now"' || true)
assert_equal '' "$bad" 'USB rows with a state other than attached now'

# The present device for the cases below: the first USB row, whatever it is.
PRESENT=$(printf '%s\n' "$LIST" | awk -F'|' '$1 == "usb" { print $2; exit }' || true)

it 'excludes hubs and controllers, which never move'
assert_no_match "$LIST" 'Hub'

it 'excludes a device whose enumeration failed (vendor 0000)'
assert_no_match "$LIST" 'usb:0000:'

it 'a Bluetooth row states paired-or-connected in exactly two spellings'
# Whether this machine has any pairings is its own business; the vocabulary is
# ours.
bad=$(printf '%s\n' "$LIST" | awk -F'|' '$1 == "bt" && $3 != "paired, not connected" && $3 != "connected now"' || true)
assert_equal '' "$bad" 'Bluetooth rows with an unknown state'

# The Bluetooth SEMANTICS need a known paired set, so they run against a
# fixture the watcher reads in place of system_profiler (TK_BT_PLIST): one
# device connected, one paired but away. Same shape system_profiler emits.
BT_FIXTURE="$FAKE_DIR/bluetooth.plist"
cat >"$BT_FIXTURE" <<'EOS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>_items</key><array><dict>
    <key>device_connected</key><array>
      <dict><key>Fixture Keyboard</key><dict><key>device_address</key><string>00:11:22:33:44:FD</string></dict></dict>
    </array>
    <key>device_not_connected</key><array>
      <dict><key>Fixture Headphones</key><dict><key>device_address</key><string>00:11:22:33:44:FF</string></dict></dict>
    </array>
  </dict></array>
</dict></array></plist>
EOS
BT_LIST=$(TK_BT_PLIST="$BT_FIXTURE" "$WATCH" --list)

it 'offers every PAIRED Bluetooth device, not just the connected ones'
# The one that is disconnected right now is precisely the one that will produce
# an arrival -- filtering to connected-only hides the choice a user most wants.
assert_match "$BT_LIST" 'bt|bt:0011223344ff|paired, not connected|Fixture Headphones'

it 'shows Bluetooth connection state without filtering on it'
assert_match "$BT_LIST" 'bt|bt:0011223344fd|connected now|Fixture Keyboard'

it 'normalises the address system_profiler gives to the bare lowercase form'
assert_no_match "$BT_LIST" '00:11:22'

it 'skips an entry with more keys than it has room for, rather than overrunning'
# CFDictionaryGetKeysAndValues writes every pair. The count used to be clamped
# AFTER the call, which bounded the loop but not the write -- a stack overflow
# waiting for system_profiler to change shape. Nine keys here; the buffer holds
# eight; the one-key entry beside it must still be listed.
WIDE_FIXTURE="$FAKE_DIR/bluetooth-wide.plist"
{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><array><dict><key>_items</key><array><dict>' \
    '<key>device_not_connected</key><array>' \
    '<dict>'
  for k in 1 2 3 4 5 6 7 8 9; do
    printf '<key>Wide %s</key><dict><key>device_address</key><string>00:11:22:33:55:%02d</string></dict>\n' "$k" "$k"
  done
  printf '%s\n' '</dict>' \
    '<dict><key>Fixture Headphones</key><dict><key>device_address</key><string>00:11:22:33:44:FF</string></dict></dict>' \
    '</array></dict></array></dict></array></plist>'
} >"$WIDE_FIXTURE"
wide=$(TK_BT_PLIST="$WIDE_FIXTURE" "$WATCH" --list 2>&1; echo "rc=$?")
assert_match "$wide" 'rc=0' "the watcher must survive the entry: $wide"
assert_no_match "$wide" 'Wide' 'the oversized entry is skipped whole'
assert_match "$wide" 'bt:0011223344ff|paired, not connected|Fixture Headphones'

it 'Bluetooth presence means CONNECTED, never merely paired'
# A paired-but-away device must read as absent, or its arrival can never be an
# edge -- the failure shape the Windows side measured on PnP presence.
out=$(TK_BT_PLIST="$BT_FIXTURE" "$WATCH" --test-trigger --device bt:0011223344fd --device bt:0011223344ff --timeout 1 2>&1 || true)
assert_match "$out" 'bt:0011223344fd'
assert_match "$out" 'here now'
assert_match "$out" 'bt:0011223344ff'
assert_match "$out" 'not here'

it 'lists nothing twice'
dupes=$(printf '%s\n' "$LIST" | cut -d'|' -f2 | sort | uniq -d)
assert_equal '' "$dupes" 'one row per device id'

it '--list takes no lock, so it cannot disturb a running watcher'
bg_watch --device "$ABSENT" --log "$LOG"
set +e; "$WATCH" --list >/dev/null 2>&1; rc=$?; set -e
assert_equal 0 "$rc" '--list must succeed while a watcher holds the lock'

# =============================================================================
# arming, and the lock
# =============================================================================

it 'does not fire for a device that was already present at startup'
if [ -n "$PRESENT" ]; then
  kill_watchers
  : >"$LOG"
  bg_watch --device "$PRESENT" --log "$LOG"
  assert_match "$(cat "$LOG")" 'already present, not firing'
  assert_no_match "$(cat "$LOG")" 'fired:'
else skip_no_present; fi

it 'refuses to start twice'
# Two watchers would each hold their own in-memory debounce and both fire on the
# same arrival; the debounce is per-process and cannot dedupe across them.
# The lock does not depend on presence, so an absent device serves.
kill_watchers
bg_watch --device "$ABSENT" --log "$LOG"
run_bounded 8 "$WATCH" --exec /bin/echo --arg TEST --device "$ABSENT" --log "$LOG"
assert_match "$BOUNDED_OUT" 'another watcher is already running'
assert_no_match "$BOUNDED_RC" '137' 'the second watcher must exit, not keep running'

it 'the refused second watcher exits 0, not as an error'
# launchd restarts on a non-zero exit, so a redundant start must look like a
# no-op rather than a crash.
run_bounded 8 "$WATCH" --exec /bin/echo --arg TEST --device "$ABSENT" --log "$LOG"
assert_equal 0 "$BOUNDED_RC"

it 'releases the lock when it is KILLED, with nothing left to take over'
# flock is held by the file descriptor, so the kernel drops it when the process
# dies however it dies. The abandoned-lock condition the Windows side has to
# catch and take over does not exist here -- which is why there is no takeover
# code, and why looking for some would be looking for a problem this platform
# does not have.
#
# Asserted positively -- the next watcher got the lock and said so in the log --
# rather than by capturing a backgrounded process's stderr, which would make the
# command substitution wait for a process that never exits.
kill_watchers
bg_watch --device "$ABSENT" --log "$LOG"
pkill -9 -f "$WATCH" 2>/dev/null || true
sleep 0.3
: >"$LOG"
bg_watch --device "$ABSENT" --log "$LOG"
assert_match "$(cat "$LOG")" 'watching 1 device' 'the lock must be free after a kill -9'
kill_watchers

# =============================================================================
# the log
# =============================================================================

it 'rotates the log at startup once it passes the limit'
: >"$LOG"
head -c 3000 /dev/zero | tr '\0' 'x' >"$LOG"
rm -f "$LOG.1"
inode_before=$(stat -f %i "$LOG")
bg_watch --device "$ABSENT" --log "$LOG" --max-log-bytes 1000
assert_true "$([ -f "$LOG.1" ] && echo 0 || echo 1)" 'previous generation kept as .1'
assert_equal 3000 "$(stat -f %z "$LOG.1")" 'the old content is what was kept'
assert_true "$([ "$(stat -f %z "$LOG")" -lt 3000 ] && echo 0 || echo 1)" 'log started fresh'

it 'rotates by TRUNCATING, so an already-open descriptor stays valid'
# launchd opens StandardErrorPath once, when it starts the job, and the
# watcher's stderr IS that descriptor. A rename would leave it pointing at the
# renamed inode, so every line after the first rotation would land in .1 and the
# live log would stay empty -- a rotation that silently swaps which file is the
# log.
assert_equal "$inode_before" "$(stat -f %i "$LOG")" 'the live log must keep its inode'

it 'the rotated watcher still writes to the live log afterwards'
assert_match "$(cat "$LOG")" 'watching 1 device' 'output must follow the truncation, not the rename'

it 'does NOT rotate when it is the redundant second start'
# Rotation sits after the lock deliberately: a self-heal tick that finds a live
# watcher and exits must not rotate the log out from under it.
size_before=$(stat -f %z "$LOG")
rm -f "$LOG.1"
run_bounded 8 "$WATCH" --exec /bin/echo --arg TEST --device "$ABSENT" \
              --log "$LOG" --max-log-bytes 1
assert_true "$([ ! -f "$LOG.1" ] && echo 0 || echo 1)" 'a rejected start must not rotate'
assert_equal "$size_before" "$(stat -f %z "$LOG")" 'the live log was left alone'

it 'keeps only one generation'
assert_equal 0 "$(find "$FAKE_DIR" -name 'watch.log.2' | wc -l | tr -d ' ')"

# =============================================================================
# --test-trigger: the one-shot
# =============================================================================

it 'reports current presence and waits, taking no lock'
# A real watcher is still running from the test above. The one-shot has to work
# alongside it, which is the whole point: it is a question about the devices,
# not a second watcher.
# `|| true`: a one-shot that times out exits 1 BY DESIGN, and under `set -e` that
# status propagates out of the capture and kills the suite.
if [ -n "$PRESENT" ]; then
  out=$("$WATCH" --test-trigger --device "$PRESENT" --device "$ABSENT" --timeout 1 2>&1 || true)
  assert_match "$out" "$PRESENT"
  assert_match "$out" 'here now'
  assert_match "$out" "$ABSENT"
  assert_match "$out" 'not here'
else
  out=$("$WATCH" --test-trigger --device "$ABSENT" --timeout 1 2>&1 || true)
  assert_match "$out" "$ABSENT"
  assert_match "$out" 'not here'
  skip_no_present
fi

it 'exits non-zero when nothing arrives'
set +e
"$WATCH" --test-trigger --device "$ABSENT" --timeout 1 >/dev/null 2>&1
rc=$?
set -e
assert_equal 1 "$rc"

it 'RUNS NOTHING, even when a watched device is present'
# Until the input values have been confirmed by someone looking at a screen, a
# pull would aim unverified values at panels. The one-shot reports; the
# installer decides.
# Asserted on what the program says it did rather than on a marker file: an
# --exec/--arg pair is length-bounded, and a marker path longer than the bound
# used to be truncated silently -- so the fire landed somewhere the assertion
# was not looking, and the mutation that proved it survived.
if [ -n "$PRESENT" ]; then
  out=$("$WATCH" --test-trigger --device "$PRESENT" --timeout 1 \
                 --exec /bin/echo --arg TEST 2>&1 || true)
  assert_no_match "$out" 'fired:'    '--test-trigger must run nothing'
  assert_no_match "$out" 'posix_spawn'
else skip_no_present; fi

it 'refuses an over-long --arg rather than truncating it'
long=$(printf 'x%.0s' $(seq 1 200))
set +e; "$WATCH" --test-trigger --device "$ABSENT" --timeout 1 --arg "$long" >/dev/null 2>&1; rc=$?; set -e
assert_equal 2 "$rc"

it 'does not rotate the log, so it cannot disturb a running watcher'
# The one-shot takes no lock, so it may run alongside a real watcher -- which
# means it must not touch the file that watcher is writing to.
kill_watchers
head -c 3000 /dev/zero | tr '\0' 'x' >"$LOG"
rm -f "$LOG.1"
"$WATCH" --test-trigger --device "$ABSENT" --timeout 1 --log "$LOG" --max-log-bytes 1 \
         >/dev/null 2>&1 || true
assert_true "$([ ! -f "$LOG.1" ] && echo 0 || echo 1)" 'the one-shot must not rotate'
assert_equal 3000 "$(stat -f %z "$LOG")" 'the one-shot must leave the log alone'

finish
