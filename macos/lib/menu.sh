# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# The two menus every list question is made of (specs/configure.md 3), and in
# both ENTER DOES WHAT THE HIGHLIGHTED ROW SAYS: a multi-select has no accept
# key, it has a `Done` row you move to.
#
# Both fall back to a typed number when the host cannot read individual keys,
# which is how the suite drives the whole flow; `q` is the fallback's `esc`.
#
# The drawing goes to stderr and the answer comes back in a global (MENU_PICK,
# MENU_PICKED), because a menu draws while it decides and $(...) is a subshell.

MENU_ITEMS=()
MENU_DETAIL=()
MENU_DISABLED=()
MENU_PICK=-1
MENU_PICKED=""
MENU_ESCAPED=0

menu_reset() { MENU_ITEMS=(); MENU_DETAIL=(); MENU_DISABLED=(); }

menu_add() { MENU_ITEMS+=("$1"); MENU_DETAIL+=("${2:-}"); }

# An empty item is a separator: a blank line, skipped by the cursor.
menu_sep() { MENU_ITEMS+=(""); MENU_DETAIL+=(""); }

# A disabled row is drawn, annotated, skipped by the cursor and unpickable;
# hiding it would change the list's shape as you answer (specs 3.2).
menu_disable() { MENU_DISABLED+=("$1"); }

menu_is_disabled() {
  local _d
  for _d in ${MENU_DISABLED[@]+"${MENU_DISABLED[@]}"}; do
    [ "$_d" = "$1" ] && return 0
  done
  return 1
}

# --- drawing -----------------------------------------------------------------

# The width rows are laid out to, capped so a wide terminal does not stretch
# a menu across it.
menu_width() {
  local _w
  _w=$(menu_term_width)
  _w=$(( _w - 1 ))
  [ "$_w" -lt 40 ] && _w=40
  [ "$_w" -gt 110 ] && _w=110
  printf '%s\n' "$_w"
}

# The width the terminal folds a line at; menu_frame counts rows against it.
menu_term_width() {
  local _w
  _w=${COLUMNS:-0}
  [ "$_w" -gt 0 ] 2>/dev/null || _w=$(tput cols 2>/dev/null || echo 100)
  [ "$_w" -lt 20 ] && _w=20
  printf '%s\n' "$_w"
}

# A row's detail wrapped to the width left for it, broken at the ", " between
# items. Nothing is ever truncated: the review screen exists to confirm what is
# about to be written. An unbreakable item overruns rather than being cut.
menu_split_detail() {
  awk -v w="$2" '
    {
      s = $0; n = 0
      while (match(s, /, /)) {
        part[++n] = substr(s, 1, RSTART + RLENGTH - 1)
        s = substr(s, RSTART + RLENGTH)
      }
      part[++n] = s
      line = ""
      for (i = 1; i <= n; i++) {
        if (line != "" && length(line) + length(part[i]) > w) {
          sub(/[ \t]+$/, "", line); print line; line = ""
        }
        line = line part[i]
      }
      if (line != "") { sub(/[ \t]+$/, "", line); print line }
    }
  ' <<EOF
$1
EOF
}

# The item column: 28, or the longest item + 1, capped at 44 (specs 3.1).
menu_itemw() {
  local _iw _it _l
  _iw=28
  for _it in ${MENU_ITEMS[@]+"${MENU_ITEMS[@]}"}; do
    [ -n "$_it" ] || continue
    _l=$(( ${#_it} + 1 ))
    [ "$_l" -gt "$_iw" ] && _iw=$_l
  done
  [ "$_iw" -gt 44 ] && _iw=44
  printf '%s\n' "$_iw"
}

# One row of text, possibly several lines when the detail does not fit.
# Emits to stdout; the caller collects.
menu_build_row() {
  local _i _marker _width _itemw _current _box _pad _d _avail _first _chunk
  _i=$1 _marker=$2 _width=$3 _itemw=$4 _current=$5 _box=${6:-}
  # A checkbox sits between the marker and the item. Continuation lines indent
  # past it so the detail column stays a column.
  [ -n "$_box" ] && _box="$_box "
  _pad=$(printf '%*s' ${#_box} '')

  _d=${MENU_DETAIL[$_i]}
  # (current) marks what is configured now; the cursor alone also means "where
  # you are".
  if [ "$_i" = "$_current" ]; then
    if [ -n "$_d" ]; then _d="$_d   (current)"; else _d="(current)"; fi
  fi

  if [ -z "$_d" ]; then
    printf '%s %s%s\n' "$_marker" "$_box" "${MENU_ITEMS[$_i]}" | sed 's/[[:space:]]*$//'
    return
  fi

  _avail=$(( _width - 4 - ${#_box} - _itemw - 1 ))
  [ "$_avail" -lt 12 ] && _avail=12

  _first=1
  menu_split_detail "$_d" "$_avail" | while IFS= read -r _chunk; do
    if [ "$_first" = "1" ]; then
      printf '%s %s%-*s %s\n' "$_marker" "$_box" "$_itemw" "${MENU_ITEMS[$_i]}" "$_chunk"
      _first=0
    else
      printf '%s %s%-*s %s\n' "$(printf '%*s' ${#_marker} '')" "$_pad" "$_itemw" '' "$_chunk"
    fi
  done
}

# Repaint a block in place. MENU_DRAWN holds the rows the last frame occupied,
# counted as drawn rather than inferred from the inputs.
MENU_DRAWN=0
menu_frame() {
  local _lines _width _term _n _l _rows
  _lines=$1 _width=$2
  _term=$(menu_term_width)
  if [ "$MENU_DRAWN" -gt 0 ]; then
    # Clear the previous frame's folded tails and any rows the new frame drops.
    printf '\033[%dA\033[J' "$MENU_DRAWN" >&2
  fi
  _n=0
  while IFS= read -r _l; do
    # Erase to end of line rather than pad: padding counts bytes, and a
    # terminal column is a character.
    printf '%s\033[K\n' "$_l" >&2
    # A line landing exactly on the terminal's fold occupies two rows.
    _rows=$(( 1 + ${#_l} / _term ))
    _n=$(( _n + _rows ))
  done <<EOF
$_lines
EOF
  MENU_DRAWN=$_n
}

# --- input -------------------------------------------------------------------

# Can the host read individual keys? A function so the suite can force the
# typed path.
menu_can_read_keys() {
  [ -n "${TK_TYPED:-}" ] && return 1
  [ -t 0 ] || return 1
  [ -r /dev/tty ] || return 1
  return 0
}

# The one place a key is read; a function so the suite can script it, and
# tests/keys.tests.sh drives the real one through a pty.
#
# bash 3.2 rejects a fractional `read -t`, so a lone Esc is told from an escape
# sequence with stty VTIME. The byte is read with dd rather than `read -n`,
# which leaves the terminal non-canonical, and as a number through od so NUL
# and newline survive the command substitution.
menu_read_key() {
  local _saved _b _rest
  _saved=$(stty -g </dev/tty 2>/dev/null || true)
  stty -icanon -echo min 1 time 0 </dev/tty 2>/dev/null || true
  _b=$(dd bs=1 count=1 2>/dev/null </dev/tty | od -An -tu1 | tr -d ' \n')

  if [ -z "$_b" ]; then
    [ -n "$_saved" ] && stty "$_saved" </dev/tty 2>/dev/null
    printf 'EOF\n'; return
  fi

  if [ "$_b" = "27" ]; then
    # An arrow sends three bytes at once; a lone Esc sends one. 0.1s decides.
    stty -icanon -echo min 0 time 1 </dev/tty 2>/dev/null || true
    _rest=$(dd bs=8 count=1 2>/dev/null </dev/tty)
    [ -n "$_saved" ] && stty "$_saved" </dev/tty 2>/dev/null
    case $_rest in
      '[A'|'OA') printf 'Up\n' ;;
      '[B'|'OB') printf 'Down\n' ;;
      '')        printf 'Escape\n' ;;
      *)         printf 'Other\n' ;;
    esac
    return
  fi

  [ -n "$_saved" ] && stty "$_saved" </dev/tty 2>/dev/null
  case $_b in
    # ICRNL stays on, so a carriage return usually arrives as 10; 13 is for a
    # terminal with -icrnl.
    13|10) printf 'Enter\n' ;;
    32)    printf 'Space\n' ;;
    113|81) printf 'Escape\n' ;;  # q / Q
    *)     printf 'Other\n' ;;
  esac
}

# Running out of input is not an empty answer (specs 3.5): a required prompt
# would re-ask forever. A prompt signals EOF by a non-zero RETURN, because most
# are read inside $(...) where `exit` kills only the subshell; every call site
# is `... || menu_eof`, which exits in the caller's own shell.
menu_eof() {
  printf '\n' >&2
  tk_log 'ran out of input. configure needs a terminal, or a complete script of answers.'
  exit 2
}

# A prompt with a default, read from stdin.
menu_read_line() {
  local _prompt _default _answer
  _prompt=$1 _default=${2:-}
  if [ -n "$_default" ]; then
    printf '%s [%s]: ' "$_prompt" "$_default" >&2
  else
    printf '%s: ' "$_prompt" >&2
  fi
  IFS= read -r _answer || return 3
  _answer=$(printf '%s' "$_answer" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -z "$_answer" ]; then printf '%s\n' "$_default"; else printf '%s\n' "$_answer"; fi
}

read_yesno() {
  local _prompt _default _hint _a
  _prompt=$1 _default=${2:-y}
  if [ "$_default" = "y" ]; then _hint='Y/n'; else _hint='y/N'; fi
  while :; do
    printf '%s [%s] ' "$_prompt" "$_hint" >&2
    IFS= read -r _a || menu_eof
    _a=$(printf '%s' "$_a" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case $_a in
      '')      [ "$_default" = "y" ] && return 0 || return 1 ;;
      y|yes)   return 0 ;;
      n|no)    return 1 ;;
    esac
  done
}

# --- select_one --------------------------------------------------------------
#
# One choice from a list. Sets MENU_PICK to the index, or -1 for esc.
#
#   select_one [--default N] [--current N] [--help TEXT] [--escapable|--escape-to N]
#
# What esc does depends on the menu (specs 3.3): --escapable returns -1, back
# and changing nothing; --escape-to N moves the cursor to row N (the top menu's
# Cancel) and activates nothing; with neither, esc does nothing.

# Both menus run inside this guard: Ctrl-C arrives while menu_read_key is
# blocked in dd with the terminal raw, so the handler restores it and exits 130.
MENU_TTY_SAVED=""
# The redirections are inside a group: with no controlling terminal bash
# reports the failed `</dev/tty` itself.
menu_tty_restore() {
  [ -n "$MENU_TTY_SAVED" ] && { stty "$MENU_TTY_SAVED" </dev/tty; } 2>/dev/null
  return 0
}
menu_tty_guard() {
  local _rc
  MENU_TTY_SAVED=$({ stty -g </dev/tty; } 2>/dev/null || true)
  trap 'menu_tty_restore; exit 130' INT TERM
  # Not `"$@"; _rc=$?`: under set -e a non-zero return would exit here.
  if "$@"; then _rc=0; else _rc=$?; fi
  trap - INT TERM
  return "$_rc"
}
select_one()  { menu_tty_guard select_one_body  "$@"; }
select_many() { menu_tty_guard select_many_body "$@"; }

select_one_body() {
  local _default _current _help _escapable _escapeto _sel _i _ok _s _itemw _at
  local _n _width _buf _j
  _default=0 _current=-1 _help='' _escapable=0 _escapeto=-1
  while [ $# -gt 0 ]; do
    case $1 in
      --default)   _default=$2; shift 2 ;;
      --current)   _current=$2; shift 2 ;;
      --help)      _help=$2; shift 2 ;;
      --escape-to) _escapeto=$2; shift 2 ;;
      --escapable) _escapable=1; shift ;;
      *) shift ;;
    esac
  done

  # The cursor moves over the selectable rows only.
  _sel=()
  _i=0
  while [ "$_i" -lt "${#MENU_ITEMS[@]}" ]; do
    if [ -n "${MENU_ITEMS[$_i]}" ] && ! menu_is_disabled "$_i"; then _sel+=("$_i"); fi
    _i=$(( _i + 1 ))
  done
  if [ "${#_sel[@]}" -eq 0 ]; then
    tk_log 'select_one: nothing selectable'
    MENU_PICK=-1
    return 1
  fi

  _ok=0
  for _s in "${_sel[@]}"; do [ "$_s" = "$_default" ] && _ok=1; done
  [ "$_ok" = "1" ] || _default=${_sel[0]}

  _itemw=$(menu_itemw)

  if ! menu_can_read_keys; then
    select_one_typed "$_default" "$_current" "$_help" "$_escapable" "$_itemw" "$_escapeto"
    return 0
  fi

  _at=0
  _n=0
  for _s in "${_sel[@]}"; do [ "$_s" = "$_default" ] && _at=$_n; _n=$(( _n + 1 )); done

  _width=$(menu_width)
  MENU_DRAWN=0
  while :; do
    _buf=""
    _i=0
    while [ "$_i" -lt "${#MENU_ITEMS[@]}" ]; do
      if [ -z "${MENU_ITEMS[$_i]}" ]; then
        _buf="$_buf
"
      elif menu_is_disabled "$_i"; then
        _buf="$_buf$(menu_build_row "$_i" '  -' "$_width" "$_itemw" "$_current")
"
      elif [ "$_i" = "${_sel[$_at]}" ]; then
        _buf="$_buf$(menu_build_row "$_i" '  >' "$_width" "$_itemw" "$_current")
"
      else
        _buf="$_buf$(menu_build_row "$_i" '   ' "$_width" "$_itemw" "$_current")
"
      fi
      _i=$(( _i + 1 ))
    done
    [ -n "$_help" ] && _buf="$_buf
$_help
"
    if [ "$_escapable" = "1" ]; then
      _buf="$_buf
  up/down move   enter choose   esc back"
    else
      _buf="$_buf
  up/down move   enter choose"
    fi
    menu_frame "$_buf" "$_width"

    case $(menu_read_key) in
      Up)     _at=$(( (_at - 1 + ${#_sel[@]}) % ${#_sel[@]} )) ;;
      Down)   _at=$(( (_at + 1) % ${#_sel[@]} )) ;;
      Enter)  printf '\n' >&2; MENU_PICK=${_sel[$_at]}; return 0 ;;
      Escape)
        if [ "$_escapable" = "1" ]; then printf '\n' >&2; MENU_PICK=-1; return 0; fi
        # Move to the way out; do not take it.
        if [ "$_escapeto" -ge 0 ]; then
          _j=0
          for _s in "${_sel[@]}"; do
            [ "$_s" = "$_escapeto" ] && _at=$_j
            _j=$(( _j + 1 ))
          done
        fi
        ;;
      EOF)    MENU_PICK=-1; return 0 ;;
    esac
  done
}

# The typed fallback: a numbered list and a prompt; `q` is its `esc`.
select_one_typed() {
  local _default _current _help _escapable _itemw _escapeto _i _l _first _pick
  local _idx _s
  _default=$1 _current=$2 _help=$3 _escapable=$4 _itemw=$5 _escapeto=${6:--1}

  _i=0
  while [ "$_i" -lt "${#MENU_ITEMS[@]}" ]; do
    if [ -z "${MENU_ITEMS[$_i]}" ]; then
      printf '\n' >&2
    elif menu_is_disabled "$_i"; then
      menu_build_row "$_i" '   ' 100 "$_itemw" "$_current" |
        while IFS= read -r _l; do printf '   -- %s\n' "${_l#    }" >&2; done
    else
      _first=1
      menu_build_row "$_i" '   ' 100 "$_itemw" "$_current" |
        while IFS= read -r _l; do
          if [ "$_first" = "1" ]; then printf '  %2d) %s\n' "$(( _i + 1 ))" "${_l#    }" >&2; _first=0
          else printf '      %s\n' "${_l#    }" >&2; fi
        done
    fi
    _i=$(( _i + 1 ))
  done
  [ -n "$_help" ] && { printf '\n' >&2; printf '%s\n' "$_help" >&2; }

  while :; do
    _pick=$(menu_read_line '  Choice' "$(( _default + 1 ))") || menu_eof
    if [ "$_escapable" = "1" ] && [ "$_pick" = "q" ]; then MENU_PICK=-1; return 0; fi
    # The typed analogue of moving the cursor: the way out becomes the default.
    if [ "$_escapeto" -ge 0 ] && [ "$_pick" = "q" ]; then _default=$_escapeto; continue; fi
    case $_pick in
      ''|*[!0-9]*) ;;
      *)
        _idx=$(( _pick - 1 ))
        for _s in "${_sel[@]}"; do
          if [ "$_s" = "$_idx" ]; then MENU_PICK=$_idx; return 0; fi
        done
        ;;
    esac
    if [ "$_escapable" = "1" ]; then
      printf '  Pick a number from the list, or q to go back.\n' >&2
    else
      printf '  Pick a number from the list.\n' >&2
    fi
  done
}

# --- select_many -------------------------------------------------------------
#
# Several choices. Enter (or space) toggles the highlighted row; Done is a row
# you move to. Sets MENU_PICKED to the space-separated indices, never empty;
# MENU_ESCAPED=1 for esc.
select_many_body() {
  local _checked _help _escapable _donelabel _state _i _c _done _cursor _note _itemw
  local _width _buf _m _b _n _s _count _key _out
  _checked='' _help='' _escapable=0 _donelabel='Done'
  while [ $# -gt 0 ]; do
    case $1 in
      --checked)    _checked=$2; shift 2 ;;
      --help)       _help=$2; shift 2 ;;
      --done-label) _donelabel=$2; shift 2 ;;
      --escapable)  _escapable=1; shift ;;
      *) shift ;;
    esac
  done

  MENU_ESCAPED=0
  _state=()
  _i=0
  while [ "$_i" -lt "${#MENU_ITEMS[@]}" ]; do _state+=(0); _i=$(( _i + 1 )); done
  for _c in $_checked; do
    if [ "$_c" -ge 0 ] 2>/dev/null && [ "$_c" -lt "${#_state[@]}" ]; then _state[_c]=1; fi
  done

  if ! menu_can_read_keys; then
    select_many_typed "$_help" "$_escapable"
    return 0
  fi

  _done=${#MENU_ITEMS[@]}
  _cursor=0
  _note=''
  _width=$(menu_width)
  _itemw=$(menu_itemw)
  MENU_DRAWN=0

  while :; do
    _buf=""
    _i=0
    while [ "$_i" -lt "${#MENU_ITEMS[@]}" ]; do
      if [ "$_i" = "$_cursor" ]; then _m='  >'; else _m='   '; fi
      if [ "${_state[$_i]}" = "1" ]; then _b='[x]'; else _b='[ ]'; fi
      # The same builder select_one uses, so the detail wraps at ", ".
      _buf="$_buf$(menu_build_row "$_i" "$_m" "$_width" "$_itemw" -1 "$_b")
"
      _i=$(( _i + 1 ))
    done

    # Done: a plain row aligned with the item text, the live count in the
    # detail column (specs 3.4).
    _n=0
    for _s in ${_state[@]+"${_state[@]}"}; do [ "$_s" = "1" ] && _n=$(( _n + 1 )); done
    if [ "$_cursor" = "$_done" ]; then _m='  >'; else _m='   '; fi
    if [ "$_n" -gt 0 ]; then _count="$_n selected"; else _count='nothing selected'; fi
    _buf="$_buf
$(printf '%s     %-*s %s' "$_m" "$_itemw" "$_donelabel" "$_count")
"
    [ -n "$_help" ] && _buf="$_buf
$_help
"
    if [ "$_escapable" = "1" ]; then
      _buf="$_buf
  up/down move   enter toggles the highlighted row   esc back"
    else
      _buf="$_buf
  up/down move   enter toggles the highlighted row"
    fi
    [ -n "$_note" ] && _buf="$_buf
$_note"
    menu_frame "$_buf" "$_width"

    _key=$(menu_read_key)
    _note=''
    case $_key in
      Escape) if [ "$_escapable" = "1" ]; then printf '\n' >&2; MENU_PICKED=''; MENU_ESCAPED=1; return 0; fi ;;
      Up)     _cursor=$(( (_cursor - 1 + _done + 1) % (_done + 1) )) ;;
      Down)   _cursor=$(( (_cursor + 1) % (_done + 1) )) ;;
      Space)  if [ "$_cursor" != "$_done" ]; then
                if [ "${_state[$_cursor]}" = "1" ]; then _state[_cursor]=0; else _state[_cursor]=1; fi
              fi ;;
      Enter)
        if [ "$_cursor" != "$_done" ]; then
          if [ "${_state[$_cursor]}" = "1" ]; then _state[_cursor]=0; else _state[_cursor]=1; fi
          continue
        fi
        _out=''
        _i=0
        while [ "$_i" -lt "${#_state[@]}" ]; do
          [ "${_state[$_i]}" = "1" ] && _out="$_out $_i"
          _i=$(( _i + 1 ))
        done
        if [ -n "$_out" ]; then
          printf '\n' >&2
          MENU_PICKED=${_out# }
          return 0
        fi
        _note='  Nothing is checked -- move to a row and press enter to check it.'
        ;;
      EOF) MENU_PICKED=''; MENU_ESCAPED=1; return 0 ;;
    esac
  done
}

select_many_typed() {
  local _help _escapable _i _mark _pre _pick _out _old _n
  _help=$1 _escapable=$2

  _i=0
  while [ "$_i" -lt "${#MENU_ITEMS[@]}" ]; do
    if [ "${_state[$_i]}" = "1" ]; then _mark='*'; else _mark=' '; fi
    printf '  %s%3d) %s  %s\n' "$_mark" "$(( _i + 1 ))" "${MENU_ITEMS[$_i]}" "${MENU_DETAIL[$_i]}" >&2
    _i=$(( _i + 1 ))
  done
  [ -n "$_help" ] && { printf '\n' >&2; printf '%s\n' "$_help" >&2; }

  _pre=''
  _i=0
  while [ "$_i" -lt "${#_state[@]}" ]; do
    [ "${_state[$_i]}" = "1" ] && _pre="$_pre,$(( _i + 1 ))"
    _i=$(( _i + 1 ))
  done
  _pre=${_pre#,}

  while :; do
    _pick=$(menu_read_line '  Numbers, comma-separated' "$_pre") || menu_eof
    if [ "$_escapable" = "1" ] && [ "$_pick" = "q" ]; then
      MENU_PICKED=''; MENU_ESCAPED=1; return 0
    fi
    _out=''
    _old=$IFS; IFS=,
    for _n in $_pick; do
      IFS=$_old
      _n=$(printf '%s' "$_n" | tr -d '[:space:]')
      case $_n in
        ''|*[!0-9]*) continue ;;
      esac
      if [ "$_n" -ge 1 ] && [ "$_n" -le "${#MENU_ITEMS[@]}" ]; then _out="$_out $(( _n - 1 ))"; fi
      IFS=,
    done
    IFS=$_old
    if [ -n "$_out" ]; then MENU_PICKED=${_out# }; return 0; fi
    if [ "$_escapable" = "1" ]; then
      printf '  Pick at least one, or q to go back.\n' >&2
    else
      printf '  Pick at least one.\n' >&2
    fi
  done
}
