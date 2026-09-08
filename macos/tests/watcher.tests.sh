#!/bin/bash
#
# The watcher: its candidate list, its matching rule, its single-instance lock,
# its log rotation and its one-shot mode.
#
# The real binary throughout, and it cannot move a monitor: --exec points at
# /bin/echo, so the switcher it spawns is echo. Presence is driven through the
# two fixtures the watcher reads in place of the machine: TK_USB_LIST (rows of
# vendor|product|name|where|role, polled) and TK_BT_PLIST (system_profiler's
# shape). Rewriting a fixture between polls is an arrival the watcher cannot
# tell from a real one. A few cases run against this machine's real devices
# and assert only properties of the rows, never a particular device.
#
# HOME is a temp directory, so the lock under "Library/Application
# Support/trigger-kvm" is a fresh one and an installed watcher is not disturbed.

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
ABSENT=usb:dead:beef

# The USB fixture. Written to a temp file and renamed, so a poll never reads a
# half-written file as "everything left".
USB="$FAKE_DIR/usb.list"
usb_fixture() { printf '%s\n' "$@" >"$USB.tmp"; mv -f "$USB.tmp" "$USB"; }

# Two receivers of one model reporting one name (this desk), a keyboard that
# shares their id but not their name (the Windows desk), a device on its own,
# a hub, and a node whose enumeration failed.
TWIN_A='046d|c547|USB Receiver|00130000|mouse, keyboard'
TWIN_B='046d|c547|USB Receiver|00141000|mouse, keyboard'
TWIN_C='046d|c547|USB Receiver|00150000|mouse, keyboard'
NAMED='046d|c547|G915 X LIGHTSPEED TKL|00130000|keyboard'
SOLO='1235|820a|Clarett+ 2Pre|00144000|'
HUB='05e3|0610|USB3.0 Hub|00120000|'
BROKEN='0000|0000||00160000|'

kill_watchers() { pkill -f "$WATCH" 2>/dev/null || true; sleep 0.3; }
trap 'kill_watchers' EXIT

# Background a watcher and disown it, so bash does not print "Terminated" over
# the test output when it is later killed. stderr goes INTO the log, as launchd
# does with StandardErrorPath; --log tells the watcher what to rotate.
bg_watch() {
  "$WATCH" --exec /bin/echo --arg TEST --usb-poll 0.2 "$@" >>"$LOG" 2>&1 &
  disown 2>/dev/null || true
  sleep 1
}
usb_watch() { TK_USB_LIST="$USB" bg_watch "$@"; }

# Run something that is SUPPOSED to exit promptly, and fail rather than hang if
# it does not: a watcher that wrongly keeps running would wedge the suite.
# macOS has no timeout(1), hence the watchdog.
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

report() { TK_USB_LIST="$USB" "$WATCH" --report "$@" 2>/dev/null; }

# =============================================================================
# --list: what could be a trigger
# =============================================================================

usb_fixture "$TWIN_A" "$TWIN_B" "$SOLO" "$HUB" "$BROKEN"
LIST=$(TK_USB_LIST="$USB" "$WATCH" --list)

it 'lists candidates as kind|key|state|name|role|token|where'
assert_match "$LIST" 'usb|usb:1235:820a|attached now|Clarett+ 2Pre||clarett-2pre|00144000'
assert_match "$LIST" 'usb|usb:046d:c547|attached now|USB Receiver|mouse, keyboard|usb-receiver|00130000'

it 'lists one row per DEVICE, so two of one model are two rows sharing a key'
assert_equal 2 "$(printf '%s\n' "$LIST" | grep -c '|usb:046d:c547|')"
assert_match "$LIST" 'usb-receiver|00141000'

it 'filters nothing by name: a hub is a row like any other'
# specs/configure.md 7.1. "Looks internal" is a guess, and the person choosing
# knows their desk.
assert_match "$LIST" 'USB3.0 Hub'

it 'withholds only a node whose enumeration failed (vendor 0000)'
assert_no_match "$LIST" 'usb:0000:'

it 'the token is the name reduced to [a-z0-9-], one dash per run of anything else'
usb_fixture '046d|c547|G915 X  LIGHTSPEED (TKL)|00130000|keyboard'
assert_match "$(TK_USB_LIST="$USB" "$WATCH" --list)" '|g915-x-lightspeed-tkl|'

it 'a name carrying the row separator or a control character is still one row'
usb_fixture "$(printf '046d|c547|Odd\tName|00130000|keyboard')"
assert_match "$(TK_USB_LIST="$USB" "$WATCH" --list)" '|Odd Name|keyboard|odd-name|'

# Against this machine: the shape of what IOKit yields, never a particular device.
REAL=$("$WATCH" --list)

it 'the real enumeration yields well-formed rows'
bad=$(printf '%s\n' "$REAL" | grep -vc '^\(usb\|bt\)|[a-z]*:[0-9a-f:]*|[^|]*|' || true)
assert_equal 0 "$bad" "malformed rows in: $REAL"
bad=$(printf '%s\n' "$REAL" | awk -F'|' '$1 == "usb" && $3 != "attached now"' || true)
assert_equal '' "$bad" 'USB has no paired-but-absent state'
bad=$(printf '%s\n' "$REAL" | awk -F'|' '$1 == "bt" && $3 != "paired, not connected" && $3 != "connected now"' || true)
assert_equal '' "$bad" 'Bluetooth rows with an unknown state'
dupes=$(printf '%s\n' "$REAL" | cut -d'|' -f2,7 | sort | uniq -d)
assert_equal '' "$dupes" 'the same device must not appear twice'
bad=$(printf '%s\n' "$REAL" |
      awk -F'|' '$1 == "usb" && $4 != "(unnamed)" && $6 !~ /^[a-z0-9-]+$/ { print $2 " name=" $4 " token=" $6 }')
assert_equal '' "$bad" 'a named device must yield a token in [a-z0-9-]'
bad=$(printf '%s\n' "$REAL" | awk -F'|' '$1 == "usb" && $7 != "" && $7 !~ /^[a-z0-9-]+$/ { print $2 }')
assert_equal '' "$bad" 'a port must be writable as a where suffix'

it 'and lists every IOUSBHostDevice ioreg sees, once each'
# ioreg is an independent oracle: deriving the expectation from the list under
# test could not catch a dropped row. Interface nodes repeat their parent's ids
# and are not devices, so only IOUSBHostDevice nodes count.
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
    if not e.get("idVendor") or "idProduct" not in e: continue
    k = "%04x:%04x" % (e["idVendor"], e["idProduct"])
    count[k] = count.get(k, 0) + 1
for k, v in count.items(): print(k, v)
' 2>/dev/null || true)
if [ -z "$oracle" ]; then
  skip_case 'no USB device is attached (or python3 is absent)'
else
  # A here-string, not a pipe: `cmd | while read` runs the loop in a subshell
  # and every assertion inside it is lost with it.
  while read -r oid on; do
    [ -n "$oid" ] || continue
    n=$(printf '%s\n' "$REAL" | awk -F'|' -v k="usb:$oid" '$1 == "usb" && $2 == k' | wc -l | tr -d ' ')
    assert_equal "$on" "$n" "usb:$oid must appear once per device, and ioreg sees $on"
  done <<EOF
$oracle
EOF
fi

it '--list takes no lock, so it cannot disturb a running watcher'
bg_watch --device "$ABSENT" --log "$LOG"
set +e; "$WATCH" --list >/dev/null 2>&1; rc=$?; set -e
assert_equal 0 "$rc" '--list must succeed while a watcher holds the lock'
kill_watchers

# Bluetooth, from a fixture in system_profiler's shape: one device connected,
# one paired but away.
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
# an arrival.
assert_match "$BT_LIST" 'bt|bt:0011223344ff|paired, not connected|Fixture Headphones'

it 'shows Bluetooth connection state without filtering on it'
assert_match "$BT_LIST" 'bt|bt:0011223344fd|connected now|Fixture Keyboard'

it 'normalises the address system_profiler gives to the bare lowercase form'
assert_no_match "$BT_LIST" '00:11:22'

it 'lists one Bluetooth row per address'
btdupes=$(printf '%s\n' "$BT_LIST" | awk -F'|' '$1 == "bt" { print $2 }' | sort | uniq -d)
assert_equal '' "$btdupes"

it 'skips an entry with more keys than it has room for, rather than overrunning'
# CFDictionaryGetKeysAndValues writes every pair, so the count is checked before
# the call. Nine keys here; the buffer holds eight; the entry beside it lists.
WIDE_FIXTURE="$FAKE_DIR/bluetooth-wide.plist"
{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
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

# =============================================================================
# what it refuses at startup (specs/detector.md 4)
# =============================================================================

it 'refuses a device entry that is not exactly usb:VVVV:PPPP or bt: plus twelve hex digits'
# Bounded: a watcher that wrongly ACCEPTS the entry would arm and run forever.
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

it 'refuses a malformed suffix by name, rather than reading it as the bare id'
# A malformed entry quietly becoming the bare id would watch EVERY device
# sharing it: "never fall back to the whole id", broken by the parser.
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

it 'refuses a debounce or settle that is not seconds, rather than reading it as zero'
for flag in --debounce --settle; do
  run_bounded 3 "$WATCH" --exec /bin/echo --device "$ABSENT" "$flag" three --log "$LOG"
  assert_equal 2 "$BOUNDED_RC" "$flag three must be refused: $BOUNDED_OUT"
  assert_match "$BOUNDED_OUT" "$flag must be seconds like 3 or 0.75, not 'three'"
  run_bounded 3 "$WATCH" --exec /bin/echo --device "$ABSENT" "$flag" '3 s' --log "$LOG"
  assert_equal 2 "$BOUNDED_RC" "$flag '3 s' must be refused: $BOUNDED_OUT"
done
kill_watchers

# =============================================================================
# 4.1: matching, as --report shows it (specs/detector.md 4.1, status.md 4.1)
# =============================================================================

usb_fixture "$TWIN_A" "$TWIN_B" "$SOLO"

it 'an entry with no suffix means every device with that id'
assert_match "$(report --device usb:046d:c547 --device usb:1235:820a)" 'usb:046d:c547|present|2'
assert_match "$(report --device usb:1235:820a)" 'usb:1235:820a|present|1'

it 'a device that is not attached is absent'
assert_match "$(report --device "$ABSENT")" "$ABSENT|absent|0"

it 'a token nothing carries matches NOTHING, never the whole id'
# The cost of falling back is concrete: a visitor's identical dongle would
# produce an arrival edge and pull the monitors over unbidden.
assert_match "$(report --device usb:046d:c547@no-such-device-token)" '|absent|0'

it 'a token held by exactly one device selects it, and the port is not consulted'
usb_fixture "$NAMED" "$TWIN_B" "$SOLO"
assert_match "$(report --device usb:046d:c547@g915-x-lightspeed-tkl)" '|present|1'
out=$(report --device usb:046d:c547@g915-x-lightspeed-tkl@00130000)
assert_match "$out" '|present|1'
assert_no_match "$out" '|where|' 'the token resolved it, so the port decided nothing'
assert_match "$(report --device usb:046d:c547@g915-x-lightspeed-tkl@ffffffff)" '|present|1' \
  'a stale port must not unmatch a resolving token'

it 'several devices sharing a token, with none at the port, is AMBIGUOUS'
usb_fixture "$TWIN_A" "$TWIN_B" "$SOLO"
assert_match "$(report --device usb:046d:c547@usb-receiver)" '|ambiguous|2'
assert_match "$(report --device usb:046d:c547@usb-receiver@ffffffff)" '|ambiguous|2'

it 'and the port breaks that tie, reporting that it was the port that decided'
# A remembered location that has gone stale is dangerous only while it is silent.
assert_match "$(report --device usb:046d:c547@usb-receiver@00141000)" '|where|1'

it 'a Bluetooth entry reports connected as present'
out=$(TK_BT_PLIST="$BT_FIXTURE" "$WATCH" --report --device bt:0011223344fd --device bt:0011223344ff 2>/dev/null)
assert_match "$out" 'bt:0011223344fd|present|1'
assert_match "$out" 'bt:0011223344ff|absent|0'

# =============================================================================
# arming, firing, and the edge (specs/detector.md 2)
# =============================================================================

it 'does not fire for a device already present at startup'
kill_watchers
: >"$LOG"
usb_fixture "$SOLO"
usb_watch --device usb:1235:820a --log "$LOG"
assert_match "$(cat "$LOG")" 'armed (1 already present, not firing)'
assert_no_match "$(cat "$LOG")" 'fired:'

it 'fires when a watched device leaves and arrives again'
usb_fixture
sleep 0.5
usb_fixture "$SOLO"
sleep 2
assert_match "$(cat "$LOG")" 'arrival usb:1235:820a'
assert_match "$(cat "$LOG")" 'fired: /bin/echo TEST' "$(cat "$LOG")"
kill_watchers

it 'the arm pass honours the token: a token nothing carries arms on nothing'
: >"$LOG"
usb_fixture "$TWIN_A" "$TWIN_B"
usb_watch --device usb:046d:c547@no-such-device-token --log "$LOG" --verbose
assert_match "$(cat "$LOG")" '(0 already present, not firing)'
kill_watchers

it 'the edge belongs to the device that arrived: a twin arriving beside the configured one is not one'
# The configured receiver sits at its remembered port. The other one is
# unplugged and plugged back in. The entry still resolves to the configured
# one, and nothing arrived that the entry names.
: >"$LOG"
usb_fixture "$TWIN_A" "$TWIN_B"
usb_watch --device usb:046d:c547@usb-receiver@00130000 --log "$LOG" --verbose
assert_match "$(cat "$LOG")" 'the remembered port decided which device this is'
usb_fixture "$TWIN_A"
sleep 0.5
usb_fixture "$TWIN_A" "$TWIN_B"
sleep 2
assert_match "$(cat "$LOG")" 'a device sharing its id arrived, but not the one it names'
assert_no_match "$(cat "$LOG")" 'fired:' "$(cat "$LOG")"

it 'and the configured device arriving IS one'
usb_fixture "$TWIN_B"
sleep 0.5
usb_fixture "$TWIN_A" "$TWIN_B"
sleep 2
assert_match "$(cat "$LOG")" 'arrival usb:046d:c547@usb-receiver@00130000'
assert_match "$(cat "$LOG")" 'fired:' "$(cat "$LOG")"
kill_watchers

it 'a device sharing the id but not the token arriving is not an edge either'
: >"$LOG"
usb_fixture "$NAMED"
usb_watch --device usb:046d:c547@g915-x-lightspeed-tkl --log "$LOG" --verbose
usb_fixture "$NAMED" "$TWIN_B"
sleep 2
assert_match "$(cat "$LOG")" 'but not the one it names'
assert_no_match "$(cat "$LOG")" 'fired:' "$(cat "$LOG")"
kill_watchers

# =============================================================================
# 4.1: ambiguity is a state
# =============================================================================

it 'refuses to start when every configured trigger is ambiguous'
# A watcher that would run and never fire is the one case where refusing is
# the kinder answer, and it is loud in the log.
usb_fixture "$TWIN_A" "$TWIN_B"
run_bounded 8 env TK_USB_LIST="$USB" "$WATCH" --exec /bin/echo --arg TEST --device usb:046d:c547@usb-receiver --log "$LOG"
assert_match "$BOUNDED_OUT" 'AMBIGUOUS'
assert_match "$BOUNDED_OUT" 'REFUSING to watch'
assert_match "$BOUNDED_OUT" 'nothing could ever fire'
assert_equal 2 "$BOUNDED_RC"

it 'but keeps watching the others when only SOME entries are ambiguous'
: >"$LOG"
usb_fixture "$TWIN_B" "$TWIN_C" "$SOLO"
usb_watch --device usb:046d:c547@usb-receiver@00130000 --device usb:1235:820a --log "$LOG"
assert_match "$(cat "$LOG")" 'AMBIGUOUS'
assert_match "$(cat "$LOG")" 'the rest keep watching'
assert_match "$(cat "$LOG")" 'watching 1 device'

it 'leaving ambiguity is not an arrival: it re-baselines and does not fire'
# One twin unplugged: the entry now resolves, to the twin that is left.
usb_fixture "$TWIN_B" "$SOLO"
sleep 2
assert_no_match "$(cat "$LOG")" 'fired:' "$(cat "$LOG")"

it 'and the configured device arriving afterwards fires, with the port deciding'
usb_fixture "$TWIN_A" "$TWIN_B" "$SOLO"
sleep 2
assert_match "$(cat "$LOG")" 'resolves to one device again'
assert_match "$(cat "$LOG")" 'the remembered port decided'
assert_match "$(cat "$LOG")" 'fired:' "$(cat "$LOG")"
kill_watchers

# =============================================================================
# the lock (specs/detector.md 1)
# =============================================================================

it 'refuses to start twice'
# Two watchers would each hold their own debounce and both fire on the same
# arrival. The lock does not depend on presence, so an absent device serves.
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
kill_watchers

LOCKFILE="$HOME/Library/Application Support/trigger-kvm/watcher.lock"

it 'refuses to run when the lock cannot be established, rather than running unlocked'
# A directory where the lock file goes: open fails for a reason that is not
# "held", and a watcher must never run without the lock.
rm -f "$LOCKFILE"; mkdir "$LOCKFILE"
run_bounded 8 "$WATCH" --exec /bin/echo --arg TEST --device "$ABSENT" --log "$LOG"
rmdir "$LOCKFILE"
assert_equal 2 "$BOUNDED_RC" "$BOUNDED_OUT"
assert_match "$BOUNDED_OUT" 'REFUSING to watch: cannot open the single-instance lock'
assert_no_match "$BOUNDED_OUT" 'watching'

# --lock-status: the question specs/status.md 2 makes `status` ask. The real
# lock, because a fake could only prove that `status` prints what it is told.

it 'answers "running" while a watcher holds the lock'
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
set +e; out=$("$WATCH" --lock-status 2>&1); set -e
assert_equal 'none' "$out" 'the previous query must not still hold the lock'

it 'creates no lock file on a machine that has never run a watcher'
# A file left behind would read as a running watcher under the rule below.
rm -f "$LOCKFILE"
set +e; out=$("$WATCH" --lock-status 2>&1); set -e
assert_equal 'none' "$out"
assert_true "$([ ! -e "$LOCKFILE" ] && echo 0 || echo 1)" 'asking must not create the lock file'

it 'reads a lock it cannot OPEN as running, never as absent'
# specs/status.md 2: that is what a watcher in another session looks like from
# here. Root can open anything, so this proves nothing as root.
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
# flock is held by the descriptor, so the kernel drops it however the process
# dies. Asserted positively: the next watcher got the lock and said so.
bg_watch --device "$ABSENT" --log "$LOG"
pkill -9 -f "$WATCH" 2>/dev/null || true
sleep 0.3
: >"$LOG"
bg_watch --device "$ABSENT" --log "$LOG"
assert_match "$(cat "$LOG")" 'watching 1 device' 'the lock must be free after a kill -9'
kill_watchers

# =============================================================================
# settle: the ARRIVING device must still be there (specs/detector.md 2)
# =============================================================================
#
# Through the Bluetooth fixture, so both sources are exercised. A is present
# throughout; B arrives, and either vanishes inside the settle window or stays.

BT_FLIP="$FAKE_DIR/bluetooth-flip.plist"
bt_fixture() {  # bt_fixture <connected addresses...>
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><array><dict><key>_items</key><array><dict>' '<key>device_connected</key><array>'
    for a in "$@"; do printf '<dict><key>Dev %s</key><dict><key>device_address</key><string>%s</string></dict></dict>\n' "$a" "$a"; done
    printf '%s\n' '</array><key>device_not_connected</key><array></array>' '</dict></array></dict></array></plist>'
  } >"$BT_FLIP.tmp"
  mv -f "$BT_FLIP.tmp" "$BT_FLIP"
}

it 'ignores an arrival whose device is gone again by the end of the settle window'
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

it 'Bluetooth presence means CONNECTED, never merely paired'
out=$(TK_BT_PLIST="$BT_FIXTURE" "$WATCH" --test-trigger --device bt:0011223344fd --device bt:0011223344ff --timeout 1 2>&1 || true)
assert_match "$out" 'bt:0011223344fd'
assert_match "$out" 'here now'
assert_match "$out" 'bt:0011223344ff'
assert_match "$out" 'not here'

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
# launchd opens StandardErrorPath once and the watcher's stderr IS that
# descriptor; a rename would strand every later line in .1.
assert_equal "$inode_before" "$(stat -f %i "$LOG")" 'the live log must keep its inode'

it 'the rotated watcher still writes to the live log afterwards'
assert_match "$(cat "$LOG")" 'watching 1 device' 'output must follow the truncation, not the rename'

it 'does NOT rotate when it is the redundant second start'
size_before=$(stat -f %z "$LOG")
rm -f "$LOG.1"
run_bounded 8 "$WATCH" --exec /bin/echo --arg TEST --device "$ABSENT" \
              --log "$LOG" --max-log-bytes 1
assert_true "$([ ! -f "$LOG.1" ] && echo 0 || echo 1)" 'a rejected start must not rotate'
assert_equal "$size_before" "$(stat -f %z "$LOG")" 'the live log was left alone'

it 'keeps only one generation'
assert_equal 0 "$(find "$FAKE_DIR" -name 'watch.log.2' | wc -l | tr -d ' ')"

# =============================================================================
# --test-trigger: the one-shot (specs/detector.md 3)
# =============================================================================

it 'reports current presence and waits, taking no lock'
# A real watcher is still running from the test above. The one-shot has to
# work alongside it: it is a question about the devices, not a second watcher.
usb_fixture "$SOLO"
out=$(TK_USB_LIST="$USB" "$WATCH" --test-trigger --device usb:1235:820a --device "$ABSENT" --timeout 1 2>&1 || true)
assert_match "$out" 'usb:1235:820a        here now'
assert_match "$out" "$ABSENT        not here"

it 'reports ONE arrival and exits 0'
usb_fixture
( sleep 1; usb_fixture "$SOLO" ) &
set +e
out=$(TK_USB_LIST="$USB" "$WATCH" --test-trigger --device usb:1235:820a --timeout 6 2>&1); rc=$?
set -e
wait
assert_equal 0 "$rc" "$out"
assert_match "$out" 'usb:1235:820a arrived -- this is what fires the switch.'

it 'exits non-zero when nothing arrives'
set +e
"$WATCH" --test-trigger --device "$ABSENT" --timeout 1 >/dev/null 2>&1
rc=$?
set -e
assert_equal 1 "$rc"

it 'RUNS NOTHING, even when a watched device is present'
# Until the input values have been confirmed by someone looking at a screen, a
# pull would aim unverified values at panels. The one-shot reports.
usb_fixture "$SOLO"
out=$(TK_USB_LIST="$USB" "$WATCH" --test-trigger --device usb:1235:820a --timeout 1 \
               --exec /bin/echo --arg TEST 2>&1 || true)
assert_no_match "$out" 'fired:'    '--test-trigger must run nothing'
assert_no_match "$out" 'posix_spawn'

it 'refuses an over-long --arg rather than truncating it'
long=$(printf 'x%.0s' $(seq 1 200))
set +e; "$WATCH" --test-trigger --device "$ABSENT" --timeout 1 --arg "$long" >/dev/null 2>&1; rc=$?; set -e
assert_equal 2 "$rc"

it 'does not rotate the log, so it cannot disturb a running watcher'
kill_watchers
head -c 3000 /dev/zero | tr '\0' 'x' >"$LOG"
rm -f "$LOG.1"
"$WATCH" --test-trigger --device "$ABSENT" --timeout 1 --log "$LOG" --max-log-bytes 1 \
         >/dev/null 2>&1 || true
assert_true "$([ ! -f "$LOG.1" ] && echo 0 || echo 1)" 'the one-shot must not rotate'
assert_equal 3000 "$(stat -f %z "$LOG")" 'the one-shot must leave the log alone'

finish
