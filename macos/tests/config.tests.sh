#!/bin/bash
#
# The config reader. Every case here is a way this parser could disagree with
# windows/config.ps1, which reads and writes the same file format on the other
# machine -- so each is checked against that regex, not against what seemed
# reasonable:
#
#     ^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../lib/config.sh
. "$MAC_DIR/lib/config.sh"

fake_setup

cfg() { printf '%s\n' "$1" >"$FAKE_DIR/c"; config_load "$FAKE_DIR/c"; }

# --- the line format ---------------------------------------------------------

it 'lower-cases the key and keeps the value verbatim'
cfg 'Display.LG.Name = LG ULTRAGEAR+'
assert_equal 'LG ULTRAGEAR+' "$(config_get 'display.lg.name')"

it 'trims whitespace around the value but not inside it'
cfg 'a =    two  words   '
assert_equal 'two  words' "$(config_get 'a')"

it 'cuts the value at the first #'
cfg 'display.lg.input.0xD1 = mac        # USB-C'
assert_equal 'mac' "$(config_get 'display.lg.input.0xd1')"

it 'reads a CRLF file as if it were LF -- the spec trims \s, which includes CR'
# The CR rode on every value: `lg-alt<CR>` was an unknown method, the vendor did
# not parse, and every switch refused with a message that looked fine. Windows
# reads the same file without the CR, so this was a silent cross-platform
# disagreement about a hand-edited config.
printf 'display.lg.method = lg-alt\r\ndisplay.lg.vendor = 0x1E6D\r\n' >"$FAKE_DIR/c"
config_load "$FAKE_DIR/c"
assert_equal 'lg-alt' "$(config_get 'display.lg.method')"
assert_equal '0x1E6D' "$(config_get 'display.lg.vendor')"

it 'ignores a UTF-8 byte-order mark, which otherwise hides the first key'
printf '\357\273\277computer.this = mac\n' >"$FAKE_DIR/c"
config_load "$FAKE_DIR/c"
assert_equal 'mac' "$(config_get 'computer.this')"

it 'refuses a word above 65535, which no EDID id can be'
set +e; config_to_word 65536 >/dev/null; rc=$?; set -e
assert_equal 1 "$rc" '65536 is not a 16-bit id'
assert_equal 65535 "$(config_to_word 65535)"

it 'normalises only the documented trigger forms, and names the rest as bad'
# An unknown entry used to be prefixed into a usb: key that matched nothing,
# so the watcher armed and never fired.
cfg 'trigger.device = 046D:0843, USB:1235:820A, BT:0011223344FF, hid:1:2, bt:00:11:22:33:44:ff, usb:46d:843'
assert_equal 'usb:046d:0843 usb:1235:820a bt:0011223344ff' "$(config_trigger_devices | tr '\n' ' ' | sed 's/ $//')"
assert_equal 'hid:1:2 bt:00:11:22:33:44:ff usb:46d:843' "$(config_bad_trigger_devices | tr '\n' ' ' | sed 's/ $//')"

it 'knows what a number of seconds looks like'
for ok in 3 3.0 0.75 0 12.5; do assert_true "$(config_is_seconds "$ok" && echo 0 || echo 1)" "'$ok' is seconds"; done
for bad in three '3 s' -1 .5 3. '' 1e2; do assert_true "$(config_is_seconds "$bad" && echo 1 || echo 0)" "'$bad' is not seconds"; done

it 'cuts at a # with no space before it'
cfg 'a = b#c'
assert_equal 'b' "$(config_get 'a')"

it 'treats a value that is only a comment as empty'
cfg 'a = # nothing here'
assert_equal '' "$(config_get 'a')"

it 'ignores a whole-line comment'
cfg '# computer.this = pc'
assert_equal '' "$(config_get 'computer.this')"

it 'splits on the FIRST = so a value may contain one'
cfg 'a = b=c'
assert_equal 'b=c' "$(config_get 'a')"

it 'ignores a line with no ='
cfg 'this is not a setting'
assert_equal '' "$(config_get 'this')"

it 'lets the LAST definition of a duplicated key win, as the hashtable does'
cfg 'computer.this = first
computer.this = second'
assert_equal 'second' "$(config_this_computer)"

it 'treats a missing file as empty rather than an error'
config_load "$FAKE_DIR/does-not-exist"
assert_equal '' "$(config_get 'computer.this')"

# --- byte parsing ------------------------------------------------------------
#
# These FAIL rather than defaulting, because a value that quietly became 0 would
# be an input no monitor has -- which is precisely the Windows bug that made
# every switch silently do nothing.

it 'parses 0x11, 0X11 and 17 to the same byte'
assert_equal 17 "$(config_to_byte 0x11)"
assert_equal 17 "$(config_to_byte 0X11)"
assert_equal 17 "$(config_to_byte 17)"

it 'parses a one-digit hex byte'
assert_equal 15 "$(config_to_byte 0xF)"

it 'reads a leading zero as decimal, not octal'
# $((010)) is 8 in bash and 10 in PowerShell. A silent cross-platform
# disagreement about which input to select is exactly the class of bug the
# shared config format exists to prevent.
assert_equal 10 "$(config_to_byte 010)"

it 'refuses a value that is not a byte, and prints nothing'
for bad in '' 'mac' '0x' '0x123' '256' '-1' '1.5' '0xZZ'; do
  set +e; out=$(config_to_byte "$bad"); rc=$?; set -e
  assert_true "$(( rc != 0 ? 0 : 1 ))" "config_to_byte '$bad' should fail"
  assert_equal '' "$out" "config_to_byte '$bad' should print nothing"
done

it 'parses an EDID id as a 16-bit word'
assert_equal 7789 "$(config_to_word 0x1E6D)"
assert_equal 40607 "$(config_to_word 0x9E9F)"

it 'refuses an EDID id that is not a word'
for bad in '' 'GSM' '0x1E6D0' '0x'; do
  set +e; out=$(config_to_word "$bad"); rc=$?; set -e
  assert_true "$(( rc != 0 ? 0 : 1 ))" "config_to_word '$bad' should fail"
  assert_equal '' "$out"
done

# --- the input map -----------------------------------------------------------

it 'reads the whole map as computer -> value'
cfg "$CONFIG_THIS_DESK"
assert_equal '209' "$(config_input_for lg mac)"
assert_equal '208' "$(config_input_for lg pc)"
assert_equal '15'  "$(config_input_for asus mac)"
assert_equal '17'  "$(config_input_for asus pc)"

it 'lower-cases the computer name on the right-hand side'
cfg 'display.lg.vendor = 0x1E6D
display.lg.input.0x0F = MAC'
assert_equal '15' "$(config_input_for lg mac)"

it 'DROPS an input whose value does not parse, rather than zeroing it'
cfg 'display.lg.vendor = 0x1E6D
display.lg.input.0xZZ = mac
display.lg.input.0x0F = pc'
assert_equal ''   "$(config_input_for lg mac)"
assert_equal '15' "$(config_input_for lg pc)"

it 'reports AMBIGUOUS when two inputs name the same computer'
cfg 'display.lg.vendor = 0x1E6D
display.lg.input.0x0F = mac
display.lg.input.0x10 = mac'
assert_equal 'AMBIGUOUS' "$(config_input_for lg mac)"

it 'finds every declared display label, and only labels with a vendor'
cfg "$CONFIG_THIS_DESK"
assert_equal 'asus
lg' "$(config_display_labels)"

it 'does not treat a dotted label as a label'
cfg 'display.a.b.vendor = 0x1E6D'
assert_equal '' "$(config_display_labels)"

it 'lists the computers it knows about'
cfg "$CONFIG_THIS_DESK"
assert_equal 'mac pc' "$(config_known_computers | sort | tr '\n' ' ' | sed 's/ $//')"

# --- triggers ----------------------------------------------------------------

it 'normalises trigger devices, treating a bare pair as usb'
cfg 'trigger.device = 046D:0843, usb:1235:820a, bt:0011223344FF'
assert_equal 'usb:046d:0843 usb:1235:820a bt:0011223344ff' \
  "$(config_trigger_devices | tr '\n' ' ' | sed 's/ $//')"

finish
