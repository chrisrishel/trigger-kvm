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
