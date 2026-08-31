# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its fixtures are read by its callers

# Shared scaffolding for the tests.
#
# No framework. bats is not in the box on macOS and requiring a brew install to
# run the tests would put a dependency in front of a project whose claim is that
# it needs nothing but what ships. A test here is a script that exits non-zero,
# which is all the framework this needs -- the same shape as windows/tests.
#
# STRICTNESS MATTERS AS MUCH AS THE ASSERTIONS. The scripts under test run under
# `set -euo pipefail`, so the harness does too. Without it a whole class of
# failure is invisible here and hits the user instead: an unset variable, a
# pipeline whose middle stage failed, a function whose non-zero return was
# swallowed. The PowerShell suite learned this the expensive way -- four crashes
# were invisible in tests because the harness did not set StrictMode.

set -euo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAC_DIR=$(dirname "$TESTS_DIR")
TK="$MAC_DIR/trigger-kvm"

FAILED=0
CASE=""

# --- assertions --------------------------------------------------------------

_fail() {
  printf '  FAIL  %s\n         %s\n' "$CASE" "$1" >&2
  FAILED=$(( FAILED + 1 ))
}

it() { CASE=$1; }

assert_equal() {
  if [ "$1" != "$2" ]; then
    _fail "expected '$1', got '$2'${3:+ -- $3}"
  fi
}

assert_true() {
  if [ "$1" != "0" ]; then _fail "expected true${2:+ -- $2}"; fi
}

assert_match() {
  case $1 in
    *"$2"*) ;;
    *) _fail "'$1' does not contain '$2'${3:+ -- $3}" ;;
  esac
}

assert_no_match() {
  case $1 in
    *"$2"*) _fail "'$1' contains '$2' and should not${3:+ -- $3}" ;;
  esac
}

# The property AGENTS.md hard rule 5 asks to be asserted: not that a check ran,
# but that NOTHING WAS SENT. On Windows the null check was present, did not
# fire, and an unresolved value went on the wire as 0x00 -- an input no monitor
# has -- so every switch silently did nothing.
assert_nothing_sent() {
  _s=$(fake_sent)
  if [ -n "$_s" ]; then _fail "expected nothing on the wire, got: $_s${1:+ -- $1}"; fi
}

assert_sent() {
  assert_equal "$1" "$(fake_sent)" "${2:-}"
}

finish() {
  if [ "$FAILED" -gt 0 ]; then
    printf '%s: %d assertion(s) failed\n' "$(basename "$0")" "$FAILED" >&2
    exit 1
  fi
  exit 0
}

# --- nothing may touch a monitor ---------------------------------------------
#
# Two layers, and the outer one is the one that matters.
#
#   ddc_send is the single function that can run m1ddc, so a unit test can stand
#   in for it -- the same thing windows/tests does with Send-Input.
#
#   But the suite also replaces the m1ddc BINARY with a recorder, so the
#   guarantee does not depend on every test remembering to stub the right
#   function. Even a test that drives the whole program end to end, through code
#   paths nobody anticipated, physically cannot reach a real monitor: the only
#   m1ddc it can find writes a line to a file.

fake_setup() {
  FAKE_DIR=$(mktemp -d -t trigger-kvm-tests)
  TK_SENT="$FAKE_DIR/sent"
  : >"$TK_SENT"

  # Stands in for m1ddc. Records what it was asked to do and moves nothing.
  cat >"$FAKE_DIR/m1ddc" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >>"$TK_SENT"
EOS
  chmod +x "$FAKE_DIR/m1ddc"

  # Stands in for display-probe. Prints whatever the test says is attached.
  cat >"$FAKE_DIR/display-probe" <<'EOS'
#!/bin/sh
[ -f "$TK_FAKE_DISPLAYS" ] && cat "$TK_FAKE_DISPLAYS"
exit 0
EOS
  chmod +x "$FAKE_DIR/display-probe"

  TK_FAKE_DISPLAYS="$FAKE_DIR/displays"
  : >"$TK_FAKE_DISPLAYS"

  # Stands in for event-watch. Lists whatever the test says is attached, and
  # reports whatever the test says a one-shot would.
  cat >"$FAKE_DIR/event-watch" <<'EOS'
#!/bin/sh
case "$1" in
  --list) [ -f "$TK_FAKE_DEVICES" ] && cat "$TK_FAKE_DEVICES"; exit 0 ;;
  --test-trigger) exit "${TK_FAKE_TRIGGER_RC:-0}" ;;
esac
exit 0
EOS
  chmod +x "$FAKE_DIR/event-watch"
  TK_FAKE_DEVICES="$FAKE_DIR/devices"
  cat >"$TK_FAKE_DEVICES" <<'EOS'
usb|usb:046d:0843|attached now|Logitech Webcam C930e
usb|usb:1235:820a|attached now|Clarett+ 2Pre
bt|bt:0011223344ff|paired, not connected|AirPods Pro
EOS

  M1DDC="$FAKE_DIR/m1ddc"
  TK_PROBE="$FAKE_DIR/display-probe"
  TK_WATCHER="$FAKE_DIR/event-watch"
  export TK_SENT TK_FAKE_DISPLAYS TK_FAKE_DEVICES M1DDC TK_PROBE TK_WATCHER

  trap 'rm -rf "$FAKE_DIR"' EXIT
}

fake_reset() { : >"$TK_SENT"; }
fake_sent()  { cat "$TK_SENT"; }

# What is "attached", one row per call. Same shape as display-probe.c emits:
#   vendor|product|mfg|connector|serial|uuid|name
fake_displays() { printf '%s\n' "$@" >"$TK_FAKE_DISPLAYS"; }

# This desk, as this Mac sees it. The LG's product id is its USB-C one -- a
# LOCAL key; the Windows host sees 0x9E9D on its own DP cable.
FAKE_LG='1E6D|9E9F|GSM|DP|00001111|AAAAAAAA-0000-4000-8000-000000000001|LG ULTRAGEAR+'
FAKE_ASUS='06B3|42E0|AUS|DP|01010101|BBBBBBBB-0000-4000-8000-000000000002|PG42UQ'
# A third panel, invented: batching across panels only becomes visible at three,
# because at two hard rule 4 splits them into two rounds of one.
FAKE_DELL='10AC|A123|DEL|HDMI|00000001|33333333-3333-3333-3333-333333333333|U2720Q'

# --- configs -----------------------------------------------------------------

# Write a config and print its path.
#
# mktemp, not $RANDOM. Every caller invokes this inside $(...) -- a subshell --
# and bash 3.2 hands each subshell the same inherited generator state, so
# $RANDOM returns the SAME number every time and every fixture config ended up
# writing to one path and clobbering the others. The symptom was a suite that
# passed or failed depending on which test happened to read the file last.
make_config() {
  _f=$(mktemp "$FAKE_DIR/config.XXXXXX")
  cat >"$_f"
  printf '%s\n' "$_f"
}

# This desk's real config, from docs/macos-parity.md section 7.
CONFIG_THIS_DESK='
computer.this = mac

display.lg.vendor  = 0x1E6D
display.lg.product = 0x9E9F
display.lg.name    = LG ULTRAGEAR+
display.lg.method  = lg-alt
display.lg.input.0xD1 = mac
display.lg.input.0xD0 = pc

display.asus.vendor  = 0x06B3
display.asus.product = 0x42E0
display.asus.name    = PG42UQ
display.asus.method  = standard
display.asus.input.0x0F = mac
display.asus.input.0x11 = pc

trigger.device   = usb:046d:0843, usb:1235:820a
trigger.debounce = 3.0
trigger.settle   = 0.75
'

# Run trigger-kvm, capturing stdout+stderr, never failing the harness on a
# non-zero exit -- a refusal IS the expected outcome in most of these.
run_tk() {
  set +e
  TK_OUT=$("$TK" "$@" 2>&1)
  TK_RC=$?
  set -e
}
