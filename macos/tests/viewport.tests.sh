#!/bin/bash
# shellcheck disable=SC2329  # overrides called by the sourced menu library
# Render the real menu primitives with bounded terminal sizes and scripted keys.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
fake_setup
# Bash 3.2 can exit zero on an unbound array expansion inside a conditional
# call. A test file only succeeds after every case and finish have been reached.
VIEWPORT_FINISHED=0 VIEWPORT_STATUS=0
trap 'VIEWPORT_STATUS=$?; rm -rf "$FAKE_DIR"; [ "$VIEWPORT_FINISHED" = 1 ] || exit 1; exit "$VIEWPORT_STATUS"' EXIT

eval "$(declare -f menu_frame | sed '1s/menu_frame/original_frame/')"
menu_term_width() { cat "$FAKE_DIR/width"; }
menu_term_height() { cat "$FAKE_DIR/height"; }
menu_can_read_keys() { return 0; }
menu_frame() {
  original_frame "$@" 2>/dev/null
  local height width
  height=$(menu_term_height); width=$(menu_term_width)
  assert_true "$([ "$MENU_DRAWN" -lt "$height" ] && echo 0 || echo 1)" 'frame fits with a cursor row reserved'
  assert_match "$1" '  >' 'the current selection is visible in every frame'
  printf '%s\n' "$1" > "$FAKE_DIR/frame-$FRAME"
  # Every physical line fits: byte length is conservative for fixture Unicode.
  assert_equal '' "$(printf '%s\n' "$1" | LC_ALL=C awk -v w="$width" 'length >= w {print NR}')" 'no implicit terminal folds escape the budget'
  FRAME=$(( FRAME + 1 ))
}
menu_read_key() {
  local n key
  n=$(cat "$FAKE_DIR/key-index"); n=$(( n + 1 ))
  printf '%s' "$n" > "$FAKE_DIR/key-index"
  key=$(sed -n "${n}p" "$FAKE_DIR/keys")
  case $key in
    Small) printf '4' > "$FAKE_DIR/height"; echo Other ;;
    Resize) printf '9' > "$FAKE_DIR/height"; printf '55' > "$FAKE_DIR/width"; echo Other ;;
    '') echo EOF ;;
    *) printf '%s\n' "$key" ;;
  esac
}
menu_read_line() {
  printf 'read\n' >> "$FAKE_DIR/typed"
  if [ -f "$FAKE_DIR/answer" ]; then cat "$FAKE_DIR/answer"; else printf '%s\n' "${2:-}"; fi
}
drive() {
  rm -f "$FAKE_DIR"/frame-* "$FAKE_DIR/typed"
  printf '%s\n' "$1" | tr ' ' '\n' > "$FAKE_DIR/keys"
  printf 0 > "$FAKE_DIR/key-index"
  printf 80 > "$FAKE_DIR/width"; printf 12 > "$FAKE_DIR/height"
  FRAME=0
  shift
  "$@" 2> "$FAKE_DIR/transcript"
}
long_list() {
  menu_reset
  for i in $(seq 1 30); do menu_add "Fixture $i" ''; done
}

it 'long single-choice lists keep Home, End and wrapped arrow selection visible'
long_list
drive 'Up Down End Home PageDown PageUp End Enter' select_one
assert_equal 29 "$MENU_PICK"
assert_match "$(cat "$FAKE_DIR/frame-0")" 'of 30' 'overflow is discoverable'
assert_no_match "$(cat "$FAKE_DIR/frame-0")" 'Fixture 30' 'the first frame is a window'
assert_match "$(cat "$FAKE_DIR/frame-4")" '> Fixture 1' 'Home returns to the first item'

it 'page movement advances substantially and does not wrap at either end'
long_list
drive 'PageDown Enter' select_one
assert_true "$([ "$MENU_PICK" -gt 1 ] && [ "$MENU_PICK" -lt 29 ] && echo 0 || echo 1)"
drive 'Home PageUp Enter' select_one
assert_equal 0 "$MENU_PICK"
drive 'End PageDown Enter' select_one
assert_equal 29 "$MENU_PICK"

it 'page and end navigation skip disabled rows and separators'
long_list; menu_disable 29; MENU_ITEMS[28]=''
drive 'End Enter' select_one
assert_equal 27 "$MENU_PICK"
menu_disable 0
drive 'Home Enter' select_one
assert_equal 1 "$MENU_PICK"

it 'multi-select preserves offscreen checks and treats Done as a navigable row'
long_list
drive 'Space End Home Down Space End Enter' select_many
assert_equal '0 1' "$MENU_PICKED"
assert_match "$(cat "$FAKE_DIR/frame-2")" '>     Done' 'End reaches Done'

it 'multi-select navigation and typed input cannot select disabled or separator rows'
long_list; menu_disable 0; menu_disable 29; MENU_ITEMS[28]=''
drive 'Home Space End Up Space End Enter' select_many
assert_equal '1 27' "$MENU_PICKED"
assert_match "$(cat "$FAKE_DIR/frame-0")" '- [ ] Fixture 1' 'disabled entries retain their position'
printf '1,2,28,29,30' > "$FAKE_DIR/answer"
drive 'Small' select_many
assert_equal '1 27' "$MENU_PICKED"
rm "$FAKE_DIR/answer"

it 'wrapped details and Unicode fit without dropping content'
menu_reset
for i in $(seq 1 15); do menu_add "Panel $i" 'alpha, beta, gamma, delta, epsilon, zeta'; done
drive 'End Home Resize End Enter' select_one
assert_equal 14 "$MENU_PICK"
assert_match "$(sed -n '/> Panel 15/,$p' "$FAKE_DIR/frame-4")" 'zeta' 'the selected entry includes its last wrapped detail'
menu_reset; menu_add 'Display' '測試螢幕測試螢幕測試螢幕測試螢幕測試螢幕測試螢幕'
drive 'Enter' select_one
assert_match "$(tr -d '\n' < "$FAKE_DIR/frame-0")" '測試螢幕測試螢幕測試螢幕測試螢幕測試螢幕測試螢幕'

it 'resizing preserves current selection and checked state'
long_list
drive 'End Resize Home Enter' select_one
assert_equal 0 "$MENU_PICK"
long_list
drive 'Space End Resize Enter' select_many
assert_equal 0 "$MENU_PICKED"

it 'a tiny viewport switches to numbered input with current checks intact'
long_list
drive 'Space Small' select_many
assert_equal 0 "$MENU_PICKED"
assert_match "$(cat "$FAKE_DIR/transcript")" 'numbered'
assert_match "$(cat "$FAKE_DIR/typed")" 'read'

it 'an entry taller than the viewport remains accessible through typed fallback'
menu_reset
huge=$(printf '%0900d' 1)
menu_add 'Huge' "$huge"
drive '' select_one
assert_equal 0 "$MENU_PICK"
assert_match "$(cat "$FAKE_DIR/transcript")" "$huge"

it 'numbered fallback retains the current single-choice default and Escape'
long_list
drive 'End Small' select_one --escapable
assert_equal 29 "$MENU_PICK"
printf q > "$FAKE_DIR/answer"
drive 'Small' select_one --escapable
assert_equal -1 "$MENU_PICK"
drive 'Space Small' select_many --escapable
assert_equal 1 "$MENU_ESCAPED"
assert_equal '' "$MENU_PICKED"

VIEWPORT_FINISHED=1
finish
