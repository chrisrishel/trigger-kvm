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

# The cases that need a present device skip, visibly, when there is none. These
# are the ARM and FIRE cases -- the ones this file exists for -- so the skip is
# counted and reported rather than left to look like a pass.
skip_no_present() { skip_case 'no USB device is attached to stand in as present'; }

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

# =============================================================================
# settle: the ARRIVING device must still be there (specs/detector.md 2)
# =============================================================================
#
# Driven through the Bluetooth fixture: rewriting the plist between polls is an
# arrival edge the watcher cannot tell from a real one. A is present throughout;
# B arrives, and either vanishes inside the settle window or stays.

BT_FLIP="$FAKE_DIR/bluetooth-flip.plist"
bt_fixture() {  # bt_fixture <connected addresses...>
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><array><dict><key>_items</key><array><dict>' '<key>device_connected</key><array>'
    for a in "$@"; do printf '<dict><key>Dev %s</key><dict><key>device_address</key><string>%s</string></dict></dict>\n' "$a" "$a"; done
    printf '%s\n' '</array><key>device_not_connected</key><array></array>' '</dict></array></dict></array></plist>'
  } >"$BT_FLIP"
}

it 'ignores an arrival whose device is gone again by the end of the settle window'
kill_watchers
: >"$LOG"
bt_fixture 0011223344aa
TK_BT_PLIST="$BT_FLIP" bg_watch --device bt:0011223344aa --device bt:0011223344bb \
  --settle 1.5 --bt-poll 0.3 --debounce 0 --log "$LOG"
sleep 1
bt_fixture 0011223344aa 0011223344bb      # B arrives
sleep 0.6
bt_fixture 0011223344aa                   # ...and is gone before the settle ends; A is still here
sleep 2
assert_match "$(cat "$LOG")" 'arrival bt:0011223344bb'
assert_match "$(cat "$LOG")" 'device vanished during settle window' "$(cat "$LOG")"
assert_no_match "$(cat "$LOG")" 'fired:' 'another device being present is not the arriving device being present'

it 'and fires when the arriving device is still there'
bt_fixture 0011223344aa 0011223344bb
sleep 2.5
assert_match "$(cat "$LOG")" 'fired:' "$(cat "$LOG")"
kill_watchers

# =============================================================================
# what it refuses at startup (specs/detector.md 4)
# =============================================================================

it 'refuses a device entry that is not exactly usb:VVVV:PPPP or bt: plus twelve hex digits'
# `%x:%x` used to accept usb:46d:843 and trailing junk, and a separated
# Bluetooth address the config-side marker could never match.
# Bounded: a watcher that wrongly ACCEPTS the entry would arm and run forever,
# and the whole suite with it -- which is how the first mutation run of this
# case sat for five minutes.
for bad in usb:46d:843 usb:046d:0843x 0x046d:0x0843 bt:00:11:22:33:44:ff bt:0011223344f hid:1:2; do
  run_bounded 3 "$WATCH" --exec /bin/echo --device "$bad" --log "$LOG"
  assert_equal 2 "$BOUNDED_RC" "must refuse '$bad': $BOUNDED_OUT"
  assert_match "$BOUNDED_OUT" "bad --device '$bad'"
done
kill_watchers

it 'and still takes the documented forms, in either case'
for good in usb:046d:0843 046D:0843 bt:0011223344FF; do
  set +e; out=$("$WATCH" --test-trigger --device "$good" --timeout 1 2>&1); rc=$?; set -e
  assert_no_match "$out" 'bad --device' "'$good' is a documented form: $out"
done

it 'refuses a debounce or settle that is not seconds, rather than reading it as zero'
for flag in --debounce --settle; do
  run_bounded 3 "$WATCH" --exec /bin/echo --device "$ABSENT" "$flag" three --log "$LOG"
  assert_equal 2 "$BOUNDED_RC" "$flag three must be refused: $BOUNDED_OUT"
  assert_match "$BOUNDED_OUT" "$flag must be seconds like 3 or 0.75, not 'three'"
  run_bounded 3 "$WATCH" --exec /bin/echo --device "$ABSENT" "$flag" '3 s' --log "$LOG"
  assert_equal 2 "$BOUNDED_RC" "$flag '3 s' must be refused: $BOUNDED_OUT"
done
kill_watchers

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

it 'lists one row per DEVICE, not per id'
# This asserted "one row per device id" until revision 12, and that assertion
# encoded the bug: two devices of one model share an id, so the list showed ONE
# row for two devices, named after whichever won, with no way to pick one. The
# contract now is one row per physical device -- so a duplicate KEY is expected
# where a desk has twins, and what must never repeat is a device.
dupes=$(printf '%s\n' "$LIST" | cut -d'|' -f2,7 | sort | uniq -d)
assert_equal '' "$dupes" 'the same device must not appear twice'

it 'and where two devices DO share an id, both rows are there'
# The bug this replaced: the list showed ONE row for two devices, named after
# whichever won, so there was no way to pick one -- and presence was per id, so
# with only one of them travelling the id never went absent, the edge never
# happened, and the trigger never fired. Silently.
#
# The expectation comes from `ioreg`, an INDEPENDENT oracle, not from the list
# under test. Deriving "which ids are shared" from the list itself cannot catch a
# list that dropped the duplicate: there would be no duplicate left to look for,
# and the case would skip rather than fail -- which is exactly what happened when
# this was written the easy way.
# Counts only IOUSBHostDevice nodes -- an interface node repeats its parent's
# idVendor/idProduct and is not a second device -- and applies the same
# infrastructure filter the program does, because hubs are not candidates and
# their exclusion is not what is under test here.
oracle=$(ioreg -a -r -c IOUSBHostDevice -l 2>/dev/null |
  /usr/bin/python3 -c '
import sys, plistlib
try: d = plistlib.loads(sys.stdin.buffer.read())
except Exception: sys.exit(0)
def walk(n):
    for e in n:
        yield e
        for c in e.get("IORegistryEntryChildren", []) or []:
            yield from walk([c])
count = {}
for e in walk(d):
    if e.get("IOObjectClass") != "IOUSBHostDevice": continue
    if "idVendor" not in e or "idProduct" not in e: continue
    name = (e.get("USB Product Name") or "").lower()
    if any(w in name for w in ("hub", "host controller", "root complex")): continue
    k = "%04x:%04x" % (e["idVendor"], e["idProduct"])
    count[k] = count.get(k, 0) + 1
for k, v in count.items():
    if v > 1: print(k, v)
' 2>/dev/null || true)
if [ -z "$oracle" ]; then
  skip_case 'no two USB devices on this machine share an id (or python3 is absent)'
else
  # A here-string, NOT a pipe: `cmd | while read` puts the loop in a subshell,
  # so every assert_equal inside it increments a FAILED that is thrown away when
  # the subshell exits. This case passed against a deliberately broken build
  # until it was written this way.
  while read -r oid on; do
    [ -n "$oid" ] || continue
    n=$(printf '%s\n' "$LIST" | awk -F'|' -v k="usb:$oid" '$1 == "usb" && $2 == k' | wc -l | tr -d ' ')
    assert_equal "$on" "$n" "usb:$oid must appear once per device, and ioreg sees $on"
    ports=$(printf '%s\n' "$LIST" | awk -F'|' -v k="usb:$oid" '$2 == k { print $7 }' | sort -u | wc -l | tr -d ' ')
    assert_equal "$n" "$ports" 'each of those rows must name a different port'
  done <<EOF
$oracle
EOF
fi

it 'and Bluetooth still lists one row per address'
# A bt address really is one per device, so that dedupe stays.
btdupes=$(printf '%s\n' "$LIST" | awk -F'|' '$1 == "bt" { print $2 }' | sort | uniq -d)
assert_equal '' "$btdupes" 'one row per paired Bluetooth device'

it 'carries the role, token and port for every USB row it can read them from'
# specs/configure.md 7.1 and detector.md 4.1. Asserted as a PROPERTY of the rows
# rather than against this desk's devices: which are attached is this machine's
# business, and a suite naming one described a single desk.
usbrows=$(printf '%s\n' "$LIST" | awk -F'|' '$1 == "usb"')
if [ -z "$usbrows" ]; then
  skip_case 'no USB device is attached to read fields off'
else
  assert_equal 7 "$(printf '%s\n' "$usbrows" | head -1 | awk -F'|' '{print NF}')"
  # A token is the row's own name reduced to the config's class, so wherever a
  # row has a name it must have a token, and that token must be writable as-is.
  bad=$(printf '%s\n' "$usbrows" |
        awk -F'|' '$4 != "(unnamed)" && $6 !~ /^[a-z0-9-]+$/ { print $2 " name=" $4 " token=" $6 }')
  assert_equal '' "$bad" 'a named device must yield a token in [a-z0-9-]'
  badwhere=$(printf '%s\n' "$usbrows" | awk -F'|' '$7 != "" && $7 !~ /^[a-z0-9-]+$/ { print $2 }')
  assert_equal '' "$badwhere" 'a port must be writable as a where suffix'
fi

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

# =============================================================================
# 4.1: a vendor:product pair can name more than one device
# =============================================================================
#
# Against the real binary and this machine's real devices, asserting PROPERTIES
# rather than any particular device -- the id used below is taken from the live
# list, so this says the same thing on any desk.

it 'refuses a malformed suffix by name, rather than reading it as the bare id'
# A malformed entry quietly becoming the bare id would watch EVERY device
# sharing it -- "never fall back to the whole id", broken by the parser, at the
# one place nobody would look.
for bad in "$ABSENT@" "$ABSENT@BadCase" "$ABSENT@a@b@c" "$ABSENT@under_score"; do
  set +e; out=$("$WATCH" --report --device "$bad" 2>&1); rc=$?; set -e
  assert_equal 2 "$rc" "must refuse: $bad"
  assert_match "$out" 'bad --device'
done

it 'accepts both suffixes, and says what the grammar is when it refuses'
set +e; out=$("$WATCH" --report --device "$ABSENT@some-token@0011" 2>&1); rc=$?; set -e
assert_equal 0 "$rc" "$out"
set +e; out=$("$WATCH" --report --device "$ABSENT@Nope" 2>&1); set -e
assert_match "$out" '@token'
assert_match "$out" 'lower-case'

it 'an entry with no suffix still means every device with that id'
if [ -n "$PRESENT" ]; then
  out=$("$WATCH" --report --device "$PRESENT" 2>/dev/null)
  assert_match "$out" '|present|'
else skip_no_present; fi

it 'a token nothing carries matches NOTHING, never the whole id'
# The cost of falling back is concrete: a visitor's identical dongle would
# produce an arrival edge and pull the monitors over unbidden.
if [ -n "$PRESENT" ]; then
  out=$("$WATCH" --report --device "$PRESENT@no-such-device-token" 2>/dev/null)
  assert_match "$out" '|absent|0'
else skip_no_present; fi

it 'a token held by exactly one device selects it, and the port is not consulted'
# Taken from the live list: the id of a device whose token is unique among the
# devices sharing that id. Skips where this desk has no such device.
UNIQ=$("$WATCH" --list 2>/dev/null | awk -F'|' '
  $1 == "usb" && $6 != "" { n[$2]++; t[$2 "|" $6]++; key[$2 "|" $6] = $2 "@" $6 }
  END { for (k in t) if (t[k] == 1) { print key[k]; exit } }')
if [ -n "$UNIQ" ]; then
  out=$("$WATCH" --report --device "$UNIQ" 2>/dev/null)
  assert_match "$out" '|present|1'
  assert_no_match "$out" '|where|'
else skip_case 'no USB device on this machine has a token unique to it'; fi

it 'and a port beside a resolving token is NOT what decided it'
# 4.1: `where` must never be consulted while `token` resolves to exactly one
# device -- otherwise moving that dongle to another socket would silently stop
# the trigger firing. Given BOTH suffixes, the TOKEN still decides, and status
# must not claim the port did. A config CAN carry both: the walkthrough only
# writes them together when the token is shared, but a hand edit may do anything.
#
# The port used is the device's REAL one, deliberately. A port that matches
# nothing cannot tell "not consulted" from "consulted and found nothing"; only
# the port that WOULD match proves the check was skipped.
if [ -n "$UNIQ" ]; then
  realport=$("$WATCH" --list 2>/dev/null | awk -F'|' -v k="${UNIQ%@*}" -v t="${UNIQ#*@}" \
             '$2 == k && $6 == t { print $7; exit }')
  out=$("$WATCH" --report --device "$UNIQ@$realport" 2>/dev/null)
  assert_match "$out" '|present|1'
  assert_no_match "$out" '|where|' 'the token resolved it, so the port decided nothing'

  out=$("$WATCH" --report --device "$UNIQ@ffffffff" 2>/dev/null)
  assert_match "$out" '|present|1' 'and a STALE port must not unmatch a resolving token'
else skip_case 'no USB device on this machine has a token unique to it'; fi

it 'several devices sharing a token, with none at the port, is AMBIGUOUS'
# The reference desk has exactly this: two LIGHTSPEED receivers, both reporting
# `usb-receiver`, neither reporting a serial (docs/measurements.md 2026-09-06).
SHARED=$("$WATCH" --list 2>/dev/null | awk -F'|' '
  $1 == "usb" && $6 != "" { t[$2 "|" $6]++; key[$2 "|" $6] = $2 "@" $6 }
  END { for (k in t) if (t[k] > 1) { print key[k]; exit } }')
if [ -n "$SHARED" ]; then
  out=$("$WATCH" --report --device "$SHARED" 2>/dev/null)
  assert_match "$out" '|ambiguous|'
else skip_case 'no two devices on this machine share an id and a token'; fi

it 'and the port breaks that tie, reporting that it was the port that decided'
# 4.1: whenever `where` decides a match, SAY SO. A remembered location that has
# gone stale is dangerous only while it is silent.
if [ -n "$SHARED" ]; then
  WHERE=$("$WATCH" --list 2>/dev/null | awk -F'|' -v k="${SHARED%@*}" -v t="${SHARED#*@}" \
          '$2 == k && $6 == t { print $7; exit }')
  out=$("$WATCH" --report --device "$SHARED@$WHERE" 2>/dev/null)
  assert_match "$out" '|where|1'
else skip_case 'no two devices on this machine share an id and a token'; fi

it 'refuses to start when every configured trigger is ambiguous'
# 4.1: an ambiguous entry disables that ENTRY, not the watcher -- UNLESS nothing
# usable is left, which is the one case where the watcher would run and never
# fire. Refusing is the kinder answer and is loud in the log.
if [ -n "$SHARED" ]; then
  kill_watchers
  run_bounded 8 "$WATCH" --exec /bin/echo --arg TEST --device "$SHARED" --log "$LOG"
  assert_match "$BOUNDED_OUT" 'REFUSING to watch'
  assert_match "$BOUNDED_OUT" 'nothing could ever fire'
  assert_equal 2 "$BOUNDED_RC"
else skip_case 'no two devices on this machine share an id and a token'; fi

it 'the ARM pass honours the token too, not just the sweep'
# IOKit matches on vendor+product only, so the arm iterator cannot express a
# token -- it has to be re-asked. Without that a watch carrying `@token` arms and
# fires on ANY device sharing the id, which is "never fall back to the whole id"
# broken at the one moment nobody would look. Visible in the armed line, which
# reports the count the watch actually primed on.
if [ -n "$SHARED" ]; then
  kill_watchers
  : >"$LOG"
  # A token nothing carries: the bare id IS present, so a prime that ignored the
  # token would arm on it and report a non-zero count.
  bg_watch --device "${SHARED%@*}@no-such-device-token" --log "$LOG" --verbose
  assert_match "$(cat "$LOG")" '(0 already present, not firing)'
  kill_watchers
else skip_case 'no two devices on this machine share an id and a token'; fi

it 'but keeps watching the others when only SOME entries are ambiguous'
if [ -n "$SHARED" ] && [ -n "$PRESENT" ]; then
  kill_watchers
  : >"$LOG"
  bg_watch --device "$SHARED" --device "$ABSENT" --log "$LOG"
  assert_match "$(cat "$LOG")" 'AMBIGUOUS'
  assert_match "$(cat "$LOG")" 'the rest keep watching'
  assert_match "$(cat "$LOG")" 'watching 1 device'
  kill_watchers
else skip_case 'needs both a shared-token device and a present one'; fi

# =============================================================================
# --lock-status: the question specs/status.md 2 makes `status` ask
# =============================================================================
#
# The real binary against the real lock, because a fake could only prove that
# `status` prints what it is told. What matters here is that the ANSWER is
# right, and the lock is the only thing that knows.

LOCKFILE="$HOME/Library/Application Support/trigger-kvm/watcher.lock"

it 'answers "running" while a watcher holds the lock'
kill_watchers
bg_watch --device "$ABSENT" --log "$LOG"
set +e; out=$("$WATCH" --lock-status 2>&1); rc=$?; set -e
assert_equal 'running' "$out"
assert_equal 0 "$rc" 'exit 0 means a watcher is running'

it 'and "none" once it is gone, without disturbing anything'
kill_watchers
set +e; out=$("$WATCH" --lock-status 2>&1); rc=$?; set -e
assert_equal 'none' "$out"
assert_equal 1 "$rc" 'exit 1 means nothing holds it'

it 'leaves no lock behind, so two asked in a row both say none'
# It has to TAKE the lock to find out whether it is free, so a query that kept
# it would make the next one report a watcher that is the previous command.
# Nothing has to release it explicitly -- the process exits and the kernel drops
# the flock with the last descriptor -- so this is the guarantee being written
# down, not a call being guarded. No mutation can break it, and that is why
# there isn't one.
set +e; out=$("$WATCH" --lock-status 2>&1); set -e
assert_equal 'none' "$out" 'the previous query must not still hold the lock'

it 'creates no lock file on a machine that has never run a watcher'
# O_CREAT here would leave a file behind that the next reader cannot tell from a
# real lock -- and under the rule below, an unopenable stray would then be read
# as a running watcher.
rm -f "$LOCKFILE"
set +e; out=$("$WATCH" --lock-status 2>&1); set -e
assert_equal 'none' "$out"
assert_true "$([ ! -e "$LOCKFILE" ] && echo 0 || echo 1)" 'asking must not create the lock file'

it 'reads a lock it cannot OPEN as running, never as absent'
# specs/status.md 2: "a lock that exists but cannot be opened by this caller is a
# RUNNING watcher, not an absent one". That is what a watcher in another session
# looks like from here, and reading it as absent is the failure the rule exists
# to prevent -- on Windows it printed `watchers : 0` beside a watcher that was
# firing. Root can open anything, so this proves nothing as root.
kill_watchers
if [ "$(id -u)" = 0 ]; then
  skip_case 'running as root, which can open a mode-000 file'
else
  : >"$LOCKFILE"
  chmod 000 "$LOCKFILE"
  set +e; out=$("$WATCH" --lock-status 2>&1); rc=$?; set -e
  chmod 644 "$LOCKFILE"
  assert_equal 'running' "$out"
  assert_equal 0 "$rc"
fi
rm -f "$LOCKFILE"

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
