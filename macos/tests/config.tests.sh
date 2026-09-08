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

it 'trims a vertical tab and a form feed, which \s also covers'
printf '\vcomputer.this\v=\fmac\f\n' >"$FAKE_DIR/c"
config_load "$FAKE_DIR/c"
assert_equal 'mac' "$(config_get 'computer.this')"

it 'returns an input map in FILE order, never sorted by value'
# specs/config-format.md, "Ordering": the LG's file lists 0xD1 before 0xD0.
cfg "$CONFIG_THIS_DESK"
assert_equal 'mac	209
pc	208' "$(config_input_map lg)"

it 'refuses a word above 65535, which no EDID id can be'
set +e; config_to_word 65536 >/dev/null; rc=$?; set -e
assert_equal 1 "$rc" '65536 is not a 16-bit id'
assert_equal 65535 "$(config_to_word 65535)"

it 'normalises only the documented trigger forms, and names the rest as bad'
# An unknown entry prefixed into a usb: key would match nothing, so the watcher
# would arm and never fire.
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

# --- a device entry may say WHICH device --------------------------------------
#
# specs/config-format.md and detector.md 4.1: usb:VVVV:PPPP[@token[@where]], both
# suffixes optional, both `[a-z0-9-]+`, and CHECKED lower-case rather than
# normalised -- because the id half is case-insensitive and a suffix silently
# lower-cased on one platform and refused on another is precisely the
# disagreement this shared corpus exists to prevent.

it 'an entry with no suffix means exactly what it always meant'
cfg 'trigger.device = usb:046d:c547, 1235:820A, bt:0011223344FF'
assert_equal 'usb:046d:c547 usb:1235:820a bt:0011223344ff' \
  "$(config_trigger_devices | tr '\n' ' ' | sed 's/ $//')"
assert_equal '' "$(config_bad_trigger_devices)"

it 'accepts one suffix, and two'
cfg 'trigger.device = usb:046d:c547@g915-x-lightspeed-tkl, usb:046d:c547@usb-receiver@0003-0005'
assert_equal 'usb:046d:c547@g915-x-lightspeed-tkl usb:046d:c547@usb-receiver@0003-0005' \
  "$(config_trigger_devices | tr '\n' ' ' | sed 's/ $//')"

it 'the ID half is case-insensitive, and the suffixes are NOT'
cfg 'trigger.device = USB:046D:C547@usb-receiver'
assert_equal 'usb:046d:c547@usb-receiver' "$(config_trigger_devices)"
cfg 'trigger.device = usb:046d:c547@USB-Receiver'
assert_equal '' "$(config_trigger_devices)" 'an upper-case suffix must be refused, not lower-cased'
assert_equal 'usb:046d:c547@USB-Receiver' "$(config_bad_trigger_devices)"

it 'refuses a malformed suffix rather than reading it as a narrower entry'
# A malformed entry that quietly became the bare id would watch BOTH devices --
# which is the "never fall back to the whole id" rule broken by the parser.
for bad in 'usb:046d:c547@' 'usb:046d:c547@a@b@c' 'usb:046d:c547@has space' \
           'usb:046d:c547@under_score' 'usb:046d:c547@@x'; do
  cfg "trigger.device = $bad"
  assert_equal '' "$(config_trigger_devices)" "must refuse: $bad"
  assert_equal "$bad" "$(config_bad_trigger_devices)" "must be NAMED as bad: $bad"
done

it 'a bt entry takes no suffix'
cfg 'trigger.device = bt:0011223344ff@something'
assert_equal '' "$(config_trigger_devices)"
assert_equal 'bt:0011223344ff@something' "$(config_bad_trigger_devices)"

# --- writing: what goes in must come back out --------------------------------
#
# specs/config-format.md, "A writer must not write what it cannot read back".
# Asserted as a ROUND TRIP through the real reader rather than against expected
# output text: the property is that the two agree, and a test that only checked
# the writer's string could drift from the parser exactly as the writer did.

roundtrip() { printf '%s\n' "$(config_line 'display.x.name' "$1")" >"$FAKE_DIR/c"
              config_load "$FAKE_DIR/c"; config_get 'display.x.name'; }

it 'a value containing # survives, because # is removed and not escaped'
# The live defect: this was written intact and read back as `ACME`. There is no
# escape in this format, and inventing one is a rule two readers could differ on.
assert_equal 'ACME 1 Display' "$(roundtrip 'ACME #1 Display')"

it 'an LF-terminated EDID descriptor does not split the line in half'
# EDID descriptor strings are LF-terminated by the standard, so this wrote a
# broken line that also swallowed the key on the line after it.
assert_equal 'Panel name' "$(roundtrip "$(printf 'Panel\nname')")"

it 'a CR does not ride on the value'
assert_equal 'Panel name' "$(roundtrip "$(printf 'Panel\rname')")"

it 'leading and trailing whitespace is trimmed by the writer, not just the reader'
# The round trip alone cannot prove this -- config_load trims too, so it would
# hold either way. What depends on the WRITER trimming is version.txt: cmd_status
# reads it with a sed that strips what is before the value and not what is after,
# so an untrimmed writer hands `status` a version with spaces on the end of it.
assert_equal 'Panel' "$(roundtrip '   Panel   ')"
assert_equal 'a = Panel' "$(config_line 'a' '   Panel   ')"
assert_equal 'a = Panel' "$(config_line 'a' '#  Panel')"

it 'a tab inside a value becomes a space, as it does on Windows'
# The reader would keep an internal tab verbatim, so this is not needed for the
# round trip -- it is here so the same panel name produces the same bytes on both
# platforms. windows/config.ps1 collapses \s+, and matching it costs nothing.
assert_equal 'Panel name' "$(roundtrip "$(printf 'Panel\tname')")"

it 'an = inside a value needs no treatment and is not a second separator'
assert_equal 'W=1920' "$(roundtrip 'W=1920')"

it 'an empty value stays empty rather than becoming a broken line'
assert_equal '' "$(roundtrip '')"

it 'a value that is nothing but # and space reduces to empty, not to a stray key'
assert_equal '' "$(roundtrip '  #  ')"

it 'ordinary text is untouched'
assert_equal 'LG ULTRAGEAR+' "$(roundtrip 'LG ULTRAGEAR+')"

it 'the key is padded to line a block up, and the padding is not part of the key'
assert_equal 'display.lg.name    = LG' "$(config_line 'display.lg.name' 'LG' 18)"
printf '%s\n' "$(config_line 'display.lg.name' 'LG' 18)" >"$FAKE_DIR/c"
config_load "$FAKE_DIR/c"
assert_equal 'LG' "$(config_get 'display.lg.name')"

it 'and with no width it pads nothing'
assert_equal 'a = b' "$(config_line 'a' 'b')"

finish
