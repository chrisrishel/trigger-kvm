#!/bin/bash
#
# The two menu primitives. Everything after this depends on them.
#
# BOTH PATHS ARE EXERCISED. The typed fallback is driven by piping answers in --
# which is the reason the fallback exists, and how the walkthrough is scripted
# end to end. The key-driven path is driven by stubbing menu_read_key with a
# scripted sequence, which is the reason that is a function: the interactive
# half would otherwise ship untested, and it is the half people actually use.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../lib/common.sh
. "$MAC_DIR/lib/common.sh"
# shellcheck source=../lib/menu.sh
. "$MAC_DIR/lib/menu.sh"

fake_setup
OUT="$FAKE_DIR/menu.out"

# --- driving the menus -------------------------------------------------------

# The menus draw to stderr and answer in a global, so a test cannot capture them
# with $(...) -- that is a subshell, and the global would not come back. Send
# the drawing to a file instead.
MENU_TEXT=""

# Type answers at the fallback.
typed() {
  export TK_TYPED=1
  _answers=$1; shift
  printf '%s\n' "$_answers" > "$FAKE_DIR/answers"
  "$@" >/dev/null 2>"$OUT" <"$FAKE_DIR/answers"
  MENU_TEXT=$(cat "$OUT")
}

# Play a key sequence at the interactive path.
KEYS=""
keys() {
  unset TK_TYPED
  KEYS=$1; shift
  # The position lives in a FILE, not a variable: the menus call menu_read_key
  # inside $(...), which is a subshell, so a variable increment there is lost
  # and the stub replays key one forever. The real reader is stateless and does
  # not care, which is why this only bites the harness.
  printf '0' > "$FAKE_DIR/keyi"
  "$@" >/dev/null 2>"$OUT"
  MENU_TEXT=$(cat "$OUT")
}
# shellcheck disable=SC2329  # overrides, called by the code under test
menu_can_read_keys() { [ -z "${TK_TYPED:-}" ]; }

# Exhausting the script yields EOF, which both menus treat as "give up". Without
# that they spin on an unrecognised key forever, and a test that is one keypress
# short wedges the suite instead of failing it.
# shellcheck disable=SC2329  # an override, called by the code under test
menu_read_key() {
  _i=$(( $(cat "$FAKE_DIR/keyi") + 1 ))
  printf '%s' "$_i" > "$FAKE_DIR/keyi"
  _k=$(printf '%s\n' "$KEYS" | tr ' ' '\n' | sed -n "${_i}p")
  if [ -z "$_k" ]; then printf 'EOF\n'; else printf '%s\n' "$_k"; fi
}

three() { menu_reset; menu_add alpha one; menu_add beta two; menu_add gamma three; }

# =============================================================================
# select_one -- the key-driven path
# =============================================================================

it 'enter chooses the highlighted row'
three; keys 'Enter' select_one --default 0
assert_equal 0 "$MENU_PICK"

it 'down moves the cursor before enter takes it'
three; keys 'Down Enter' select_one --default 0
assert_equal 1 "$MENU_PICK"

it 'up wraps around to the last row'
three; keys 'Up Enter' select_one --default 0
assert_equal 2 "$MENU_PICK"

it 'starts on the row given as the default'
three; keys 'Enter' select_one --default 2
assert_equal 2 "$MENU_PICK"

it 'draws the cursor on the highlighted row and nowhere else'
three; keys 'Enter' select_one --default 1
assert_match "$MENU_TEXT" '  > beta'
assert_no_match "$MENU_TEXT" '  > alpha'

# --- separators --------------------------------------------------------------

it 'draws a separator as a blank line'
menu_reset; menu_add alpha ''; menu_sep; menu_add gamma ''
keys 'Enter' select_one --default 0
assert_match "$MENU_TEXT" 'alpha'
assert_match "$MENU_TEXT" 'gamma'

it 'skips a separator with the cursor, and it cannot be chosen'
# One Down from row 0 must land on gamma (index 2), not on the separator.
menu_reset; menu_add alpha ''; menu_sep; menu_add gamma ''
keys 'Down Enter' select_one --default 0
assert_equal 2 "$MENU_PICK"

# --- disabled rows -----------------------------------------------------------

it 'draws a disabled row, annotated, but skips it with the cursor'
# Hiding it would make the list change shape as you answer; renaming it would
# lose the only label the monitor's own menu agrees with.
menu_reset
menu_add 'DisplayPort 1' '0x0F'
menu_add 'HDMI 1'        '0x11   assigned to pc'
menu_add 'HDMI 2'        '0x12'
menu_disable 1
keys 'Down Enter' select_one --default 0
assert_equal 2 "$MENU_PICK" 'the cursor must skip the disabled row'
assert_match "$MENU_TEXT" 'HDMI 1' 'a disabled row is still drawn'
assert_match "$MENU_TEXT" 'assigned to pc' 'and still says who has it'
assert_match "$MENU_TEXT" '  - HDMI 1' 'and is marked as unpickable'

it 'never starts the cursor on a disabled row'
menu_reset; menu_add a ''; menu_add b ''; menu_add c ''
menu_disable 0
keys 'Enter' select_one --default 0
assert_no_match "$MENU_PICK" '^0$'

# --- (current) ---------------------------------------------------------------

it 'marks the configured row with (current)'
# Starting the cursor there is not enough: the cursor also means "where you
# are", so a re-run gave no way to tell an unchanged default from a deliberate
# choice.
three; keys 'Enter' select_one --default 0 --current 2
assert_match "$MENU_TEXT" '(current)'
line=$(printf '%s\n' "$MENU_TEXT" | grep gamma)
assert_match "$line" '(current)' 'the marker belongs to the configured row'
line=$(printf '%s\n' "$MENU_TEXT" | grep alpha)
assert_no_match "$line" '(current)'

it 'marks the current row even when it has no detail of its own'
menu_reset; menu_add alpha ''; menu_add beta ''
keys 'Enter' select_one --default 0 --current 1
line=$(printf '%s\n' "$MENU_TEXT" | grep beta)
assert_match "$line" '(current)'

# --- esc ---------------------------------------------------------------------

it 'esc returns -1, meaning back and change nothing'
three; keys 'Down Escape' select_one --default 0 --escapable
assert_equal -1 "$MENU_PICK"

it 'esc does nothing at all when the menu is not escapable'
# Not offered on the top menu, which has Cancel and should not discard a setup
# on a stray keypress.
three; keys 'Escape Escape Enter' select_one --default 1
assert_equal 1 "$MENU_PICK"

it 'esc MOVES the cursor to the way out rather than taking it'
# The top menu's way out is a Cancel row. Moving rather than acting is what
# keeps a stray keypress from discarding a setup.
menu_reset; menu_add alpha ''; menu_add beta ''; menu_add 'Cancel (discard changes)' ''
keys 'Escape Enter' select_one --default 0 --escape-to 2
assert_equal 2 "$MENU_PICK"
assert_match "$MENU_TEXT" '  > Cancel (discard changes)' 'the cursor lands there'

it 'and one esc alone is not enough to take it'
# Two keystrokes, never one.
menu_reset; menu_add alpha ''; menu_add beta ''; menu_add 'Cancel (discard changes)' ''
keys 'Escape' select_one --default 0 --escape-to 2
assert_equal -1 "$MENU_PICK" 'nothing was chosen -- the keys ran out first'

it 'esc does nothing at all when there is no way out to move to'
menu_reset; menu_add alpha ''; menu_add beta ''
keys 'Escape Escape Enter' select_one --default 1
assert_equal 1 "$MENU_PICK"

it 'q makes the way out the default in the typed fallback'
menu_reset; menu_add alpha ''; menu_add beta ''; menu_add 'Cancel (discard changes)' ''
typed 'q
' select_one --default 0 --escape-to 2
assert_equal 2 "$MENU_PICK"

it 'says esc is available only when it is'
three; keys 'Enter' select_one --default 0 --escapable
assert_match "$MENU_TEXT" 'esc back'
three; keys 'Enter' select_one --default 0
assert_no_match "$MENU_TEXT" 'esc back'

# =============================================================================
# wrapping -- never truncation
# =============================================================================

LONG='usb:046d:0843, usb:1235:820a, bt:0011223344ff, usb:04d9:0024, bt:0011223344fd, usb:0bda:4cb6'

it 'wraps a long detail instead of truncating it'
# The review screen exists to let someone confirm what is about to be written,
# and an ellipsis there hides exactly the thing they came to check.
menu_reset; menu_add 'Triggers' "$LONG"
COLUMNS=80 keys 'Enter' select_one --default 0
assert_no_match "$MENU_TEXT" '...'
for part in usb:046d:0843 usb:1235:820a bt:0011223344ff usb:04d9:0024 bt:0011223344fd usb:0bda:4cb6; do
  assert_match "$MENU_TEXT" "$part" "every item must survive wrapping"
done

it 'breaks at the ", " between items, never mid-identifier'
menu_reset; menu_add 'Triggers' "$LONG"
COLUMNS=80 keys 'Enter' select_one --default 0
partial=$(printf '%s\n' "$MENU_TEXT" | grep -cE '(usb|bt):[0-9a-f]{1,3}$' || true)
assert_equal 0 "$partial" 'a line must not end mid-identifier'

it 'aligns continuation lines under the detail column'
menu_reset; menu_add 'Triggers' "$LONG"
COLUMNS=80 keys 'Enter' select_one --default 0
first=$(printf '%s\n' "$MENU_TEXT" | grep -n 'Triggers' | head -1 | cut -d: -f1)
cont=$(printf '%s\n' "$MENU_TEXT" | sed -n "$(( first + 1 ))p")
lead=$(printf '%s' "$cont" | sed 's/[^ ].*//' | wc -c | tr -d ' ')
assert_true "$([ "$lead" -gt 20 ] && echo 0 || echo 1)" "continuation indented, got $lead"

it 'lets an unbreakable single item overrun rather than cutting it'
huge='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
menu_reset; menu_add 'One' "$huge"
COLUMNS=60 keys 'Enter' select_one --default 0
assert_match "$MENU_TEXT" "$huge" 'an unbreakable item must survive whole'

it 'widens the item column for a long item instead of running into the detail'
menu_reset
menu_add 'Yes, but it did not change back to mac' 'the input for mac is wrong'
menu_add 'No' ''
keys 'Enter' select_one --default 0
assert_match "$MENU_TEXT" 'back to mac  the input for mac is wrong'

# =============================================================================
# select_one -- the typed fallback
# =============================================================================

it 'numbers the rows and takes a typed number'
three; typed '2' select_one --default 0
assert_equal 1 "$MENU_PICK"
assert_match "$MENU_TEXT" '   1) alpha'
assert_match "$MENU_TEXT" '   2) beta'

it 'takes the default when the answer is empty'
three; typed '' select_one --default 2
assert_equal 2 "$MENU_PICK"

it 're-asks rather than accepting a number that is not on the list'
three; typed '9
2' select_one --default 0
assert_equal 1 "$MENU_PICK"
assert_match "$MENU_TEXT" 'Pick a number from the list'

it 'refuses a disabled row even when its number is typed'
menu_reset; menu_add a ''; menu_add b ''; menu_add c ''
menu_disable 1
typed '2
3' select_one --default 0
assert_equal 2 "$MENU_PICK"

it 'q is the typed fallback esc'
three; typed 'q' select_one --default 0 --escapable
assert_equal -1 "$MENU_PICK"

it 'q is not an escape when the menu is not escapable'
three; typed 'q
1' select_one --default 0
assert_equal 0 "$MENU_PICK"

it 'shows the disabled row in the typed list too, unnumbered'
menu_reset; menu_add a ''; menu_add 'taken' 'assigned to pc'; menu_add c ''
menu_disable 1
typed '1' select_one --default 0
assert_match "$MENU_TEXT" '   -- taken'
assert_no_match "$MENU_TEXT" '   2) taken'

# =============================================================================
# select_many
# =============================================================================

many() {
  menu_reset
  menu_add 'usb:046d:0843 ' 'USB   Logitech Webcam C930e'
  menu_add 'bt:0011223344ff' 'BT    AirPods Pro  (paired, not connected)'
  menu_add 'usb:1235:820a ' 'USB   Clarett+ 2Pre'
}

it 'ENTER TOGGLES the highlighted row -- there is no accept key'
# "space toggles, enter accepts" lost people immediately: enter is what you
# press, so the first thing it did was accept an empty list.
many; keys 'Enter Down Down Down Enter' select_many
assert_equal '0' "$MENU_PICKED"

it 'space toggles too, for anyone who reaches for it'
many; keys 'Space Down Down Down Enter' select_many
assert_equal '0' "$MENU_PICKED"

it 'toggles off again'
many; keys 'Enter Enter Down Down Down Enter' select_many --checked '1'
assert_equal '1' "$MENU_PICKED"

it 'Done is a row you move to, and it accepts'
many; keys 'Down Enter Down Down Enter' select_many
assert_equal '1' "$MENU_PICKED"

it 'Done with nothing checked REFUSES and says so'
many; keys 'Down Down Down Enter Up Enter Down Enter' select_many
assert_match "$MENU_TEXT" 'Nothing is checked'
assert_equal '2' "$MENU_PICKED"

it 'shows a live count in the detail column'
many; keys 'Enter Down Enter Down Down Enter' select_many
assert_match "$MENU_TEXT" '2 selected'
assert_equal '0 1' "$MENU_PICKED"

it 'says nothing selected when nothing is'
many; keys 'Down Down Down Enter Enter Down Down Down Enter' select_many
assert_match "$MENU_TEXT" 'nothing selected'

it 'draws Done as a plain row, not a bracketed button'
many; keys 'Enter Down Down Down Enter' select_many
assert_match "$MENU_TEXT" '     Done'
assert_no_match "$MENU_TEXT" '[Done]'

it 'starts with the given rows checked'
many; keys 'Down Down Down Enter' select_many --checked '0 2'
assert_equal '0 2' "$MENU_PICKED"

it 'esc returns nothing, distinct from an empty list'
many; keys 'Enter Escape' select_many --escapable
assert_equal 1 "$MENU_ESCAPED"
assert_equal '' "$MENU_PICKED"

it 'esc does nothing when the menu is not escapable'
many; keys 'Escape Enter Down Down Down Enter' select_many
assert_equal 0 "$MENU_ESCAPED"
assert_equal '0' "$MENU_PICKED"

it 'takes comma-separated numbers in the typed fallback'
many; typed '1,3' select_many
assert_equal '0 2' "$MENU_PICKED"

it 'refuses an empty typed answer and re-asks'
many; typed '
1' select_many
assert_equal '0' "$MENU_PICKED"
assert_match "$MENU_TEXT" 'Pick at least one'

it 'pre-fills the typed fallback with what is already checked'
many; typed '' select_many --checked '0 2'
assert_equal '0 2' "$MENU_PICKED"

it 'q is the typed fallback esc here too'
many; typed 'q' select_many --escapable
assert_equal 1 "$MENU_ESCAPED"

it 'ignores numbers outside the list rather than accepting them'
many; typed '9,2' select_many
assert_equal '1' "$MENU_PICKED"

# =============================================================================
# read_yesno
# =============================================================================

it 'takes the default on an empty answer'
printf '\n' > "$FAKE_DIR/a"
if read_yesno 'ok?' y <"$FAKE_DIR/a" 2>/dev/null; then r=yes; else r=no; fi
assert_equal yes "$r"
if read_yesno 'ok?' n <"$FAKE_DIR/a" 2>/dev/null; then r=yes; else r=no; fi
assert_equal no "$r"

it 'accepts y, yes, n and no in any case'
for a in y Y yes YES; do
  printf '%s\n' "$a" > "$FAKE_DIR/a"
  if read_yesno 'ok?' n <"$FAKE_DIR/a" 2>/dev/null; then r=yes; else r=no; fi
  assert_equal yes "$r" "answer '$a'"
done
for a in n N no NO; do
  printf '%s\n' "$a" > "$FAKE_DIR/a"
  if read_yesno 'ok?' y <"$FAKE_DIR/a" 2>/dev/null; then r=yes; else r=no; fi
  assert_equal no "$r" "answer '$a'"
done

it 'shows which way the default goes'
printf '\n' > "$FAKE_DIR/a"
read_yesno 'ok?' y <"$FAKE_DIR/a" 2>"$OUT" || true
assert_match "$(cat "$OUT")" '[Y/n]'
read_yesno 'ok?' n <"$FAKE_DIR/a" 2>"$OUT" || true
assert_match "$(cat "$OUT")" '[y/N]'

finish
