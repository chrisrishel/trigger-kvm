# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers
# shellcheck disable=SC2016  # the backticks below are prose, quoting command names
#                              in prompts and in the config's own comments

# The walkthrough.
#
# THE MENU IS THE FLOW. There is no separate first-run questionnaire: an empty
# install is this same menu with "not set" in it and the cursor already on the
# first thing that needs an answer, and a configured one is the same menu with
# the answers in it. Two flows meant two places for a change to have to be made,
# and meant that finishing a section on a fresh install dropped you into the
# NEXT section rather than back to the menu -- which is not what "done" means
# anywhere else in this program.
#
# NOTHING IS WRITTEN UNTIL SAVE, so an interrupted run leaves a working setup
# untouched rather than a half-written config plus an agent pointing at it.

# --- the researched tables ---------------------------------------------------

# Standard MCCS input values, in the channel's own order.
MCCS_NAMES=('DisplayPort 1' 'DisplayPort 2' 'HDMI 1' 'HDMI 2' 'DVI 1' 'DVI 2' 'VGA 1' 'USB-C')
MCCS_VALUES=(0x0F 0x10 0x11 0x12 0x03 0x04 0x01 0x1B)

# What a MANUFACTURER's panels answer to when the standard channel does not.
#
# Keyed by EDID VENDOR alone, never by model. A vendor:product key was one row
# per monitor someone here happened to own, on a panel whose product id is
# per-INPUT, so the key was nearly per-cable and nobody else's monitor would
# ever be in it.
#
# A dialect is OFFERED, never probed, and only after standard DDC/CI has been
# shown not to work -- most panels of every make answer 0x60 perfectly well, and
# reaching for a manufacturer channel that is not needed is how monitors get
# bricked. Values here come from documentation and measurement, never a search.
# A panel absent from this table is offered standard DDC/CI only.
# One "name=value,name=value" string per vendor rather than a per-vendor array
# name: reaching those needs eval, and an eval that builds a variable name from
# data is a thing to avoid in a program whose whole job is aiming writes.
DIALECT_VENDORS=(1E6D)
DIALECT_WHAT=(LG)
DIALECT_METHOD=(lg-alt)
DIALECT_INPUTS=('DisplayPort=0xD0,USB-C=0xD1,HDMI 1=0x90,HDMI 2=0x91')

# The dialect index for an EDID vendor, or nothing.
wt_dialect_for() {
  local _i
  _i=0
  while [ "$_i" -lt "${#DIALECT_VENDORS[@]}" ]; do
    [ "${DIALECT_VENDORS[$_i]}" = "$1" ] && { printf '%s\n' "$_i"; return 0; }
    _i=$(( _i + 1 ))
  done
  return 1
}

# --- the per-panel map, as a string ------------------------------------------
#
# "mac=0xD1,pc=0xD0" -- ordered by the order the computers were listed in, not
# by input value. Reading the config sorts by key, which is the hex, so the same
# two computers came out "mac, pc" on one panel and "pc, mac" on the next purely
# because of which socket they happened to be plugged into. The order someone
# listed their computers in is the one they will look for.
#
# A string rather than an associative array because /bin/bash on macOS is 3.2
# and has none, and because a map has to live inside an ARRAY of answers, which
# even bash 4 cannot do.

map_get() {
  printf '%s' "$1" | tr ',' '\n' |
    awk -F= -v k="$2" '$1 == k { print $2; exit }'
}

map_has() { [ -n "$(map_get "$1" "$2")" ]; }

map_computers() { printf '%s' "$1" | tr ',' '\n' | awk -F= 'NF { print $1 }'; }

map_values() { printf '%s' "$1" | tr ',' '\n' | awk -F= 'NF { print $2 }'; }

map_count() { map_computers "$1" | grep -c . || true; }

# Set, preserving position for an existing key and appending a new one.
map_set() {
  local _m _k _v _out _found _old _e
  _m=$1 _k=$2 _v=$3 _out='' _found=0
  _old=$IFS; IFS=,
  for _e in $_m; do
    IFS=$_old
    [ -n "$_e" ] || { IFS=,; continue; }
    case $_e in
      "$_k="*) _out="$_out,$_k=$_v"; _found=1 ;;
      *)       _out="$_out,$_e" ;;
    esac
    IFS=,
  done
  IFS=$_old
  [ "$_found" = "0" ] && _out="$_out,$_k=$_v"
  printf '%s\n' "${_out#,}"
}

map_del() {
  local _m _k _out _old _e
  _m=$1 _k=$2 _out=''
  _old=$IFS; IFS=,
  for _e in $_m; do
    IFS=$_old
    [ -n "$_e" ] || { IFS=,; continue; }
    case $_e in "$_k="*) ;; *) _out="$_out,$_e" ;; esac
    IFS=,
  done
  IFS=$_old
  printf '%s\n' "${_out#,}"
}

# Which computer holds a given input value on this panel, or nothing.
map_who_has() {
  printf '%s' "$1" | tr ',' '\n' |
    awk -F= -v v="$2" 'tolower($2) == tolower(v) { print $1; exit }'
}

# Rename a computer throughout a map, keeping its position.
map_rename() {
  printf '%s' "$1" | tr ',' '\n' |
    awk -F= -v o="$2" -v n="$3" 'NF { if ($1 == o) print n "=" $2; else print $0 }' |
    paste -sd, -
}

# --- computer names ----------------------------------------------------------

COMPUTER_NAME_RULE='Lowercase letters, digits and dashes.'

# What a computer may be called.
#
# ONE name, not a slug plus a friendly name. This name is a config value, an
# argument you type (`trigger-kvm to mac`) and a label in every prompt -- a
# second "display name" field would be a second thing to keep in step for the
# sake of capital letters. So the one name has to be typeable without quoting,
# which is what the character rule is for.
wt_format_name() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/[[:space:]._]\{1,\}/-/g' \
        -e 's/[^a-z0-9-]//g' \
        -e 's/--*/-/g' \
        -e 's/^-//' -e 's/-$//'
}

# Suggests rather than silently mangling. The first version stripped what it did
# not like, so "My Mac" quietly became "mymac" and the person was left wondering
# where their space went.
wt_read_name() {
  local _prompt _default _taken _raw _n
  _prompt=$1 _default=${2:-} _taken=${3:-}
  while :; do
    _raw=$(menu_read_line "  $_prompt" "$_default") || menu_eof
    if [ -z "$_raw" ]; then
      printf '  A name is needed here.\n' >&2
      continue
    fi
    _n=$(wt_format_name "$_raw")
    if [ -z "$_n" ]; then
      printf '  Nothing usable in that. %s\n' "$COMPUTER_NAME_RULE" >&2
      continue
    fi
    if [ "$_n" != "$(printf '%s' "$_raw" | tr '[:upper:]' '[:lower:]')" ]; then
      printf '  Names are what you type at a prompt, so: %s\n' "$COMPUTER_NAME_RULE" >&2
      if ! read_yesno "  Use '$_n'?" y; then _default=$_n; continue; fi
    fi
    case " $_taken " in
      *" $_n "*) printf '  There is already a computer called %s.\n' "$_n" >&2; continue ;;
    esac
    printf '%s\n' "$_n"
    return 0
  done
}

# --- state -------------------------------------------------------------------

WT_THIS=''
WT_COMPUTERS=()
WT_DEVICES=()
WT_TIER=''
WT_WANTPATH=''
WT_ONPATH=0

# One record per MANAGED display, parallel arrays indexed together.
WT_A_KEY=(); WT_A_LABEL=(); WT_A_NAME=(); WT_A_METHOD=()
WT_A_VENDOR=(); WT_A_PRODUCT=(); WT_A_MAP=()

# One record per ATTACHED display, from display-probe.
WT_F_KEY=(); WT_F_VENDOR=(); WT_F_PRODUCT=(); WT_F_MFG=(); WT_F_NAME=()

wt_answer_index() {
  local _i
  _i=0
  while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do
    [ "${WT_A_KEY[$_i]}" = "$1" ] && { printf '%s\n' "$_i"; return 0; }
    _i=$(( _i + 1 ))
  done
  return 1
}

wt_load_found() {
  local _v _p _mfg _conn _ser _uuid _name
  WT_F_KEY=(); WT_F_VENDOR=(); WT_F_PRODUCT=(); WT_F_MFG=(); WT_F_NAME=()
  while IFS='|' read -r _v _p _mfg _conn _ser _uuid _name; do
    [ -n "$_v" ] || continue
    WT_F_KEY+=("$_v:$_p")
    WT_F_VENDOR+=("0x$_v")
    WT_F_PRODUCT+=("0x$_p")
    WT_F_MFG+=("$_mfg")
    if [ -n "$_name" ]; then WT_F_NAME+=("$_name"); else WT_F_NAME+=("$_mfg panel $_v:$_p"); fi
  done <<EOF
$(display_enumerate)
EOF
}

# Rebuild the answers straight from a config, asking nothing. What the menu
# opens with on a re-run.
wt_load_answers() {
  local _i _l _v _p _vn _pn _map _c _val
  WT_A_KEY=(); WT_A_LABEL=(); WT_A_NAME=(); WT_A_METHOD=()
  WT_A_VENDOR=(); WT_A_PRODUCT=(); WT_A_MAP=()
  _i=0
  while [ "$_i" -lt "${#WT_F_KEY[@]}" ]; do
    for _l in $(config_display_labels); do
      _v=$(config_get "display.$_l.vendor"); _p=$(config_get "display.$_l.product")
      _vn=$(config_to_word "$_v") || { continue; }
      _pn=$(config_to_word "$_p") || { continue; }
      if [ "$(printf '%04X:%04X' "$_vn" "$_pn")" != "${WT_F_KEY[$_i]}" ]; then continue; fi

      # Ordered by the configured order of computers, not by input value.
      _map=''
      for _c in ${WT_COMPUTERS[@]+"${WT_COMPUTERS[@]}"}; do
        _val=$(config_input_for "$_l" "$_c")
        [ -n "$_val" ] && [ "$_val" != "AMBIGUOUS" ] && _map=$(map_set "$_map" "$_c" "$(printf '0x%02X' "$_val")")
      done
      WT_A_KEY+=("${WT_F_KEY[$_i]}")
      WT_A_LABEL+=("$_l")
      WT_A_NAME+=("$(config_display_field "$_l" name "${WT_F_NAME[$_i]}")")
      WT_A_METHOD+=("$(config_display_field "$_l" method standard)")
      WT_A_VENDOR+=("${WT_F_VENDOR[$_i]}")
      WT_A_PRODUCT+=("${WT_F_PRODUCT[$_i]}")
      WT_A_MAP+=("$_map")
      break
    done
    _i=$(( _i + 1 ))
  done
}

# --- computers ---------------------------------------------------------------

# Asked BEFORE the monitors, so a computer is described once rather than once
# per screen, and so every panel then offers the same names.
wt_computers() {
  local _first_run _me _rest _c _n _a _i _q _addrow _removerow _donerow _pick
  local _idx _victim _others _new
  printf '\n--- computers ---\n' >&2
  printf 'These monitors are shared between this computer and some others.\n' >&2
  printf 'Each one gets a name, and the name is how you switch to it:\n' >&2
  printf '    trigger-kvm to mac\n\n' >&2

  _first_run=0
  [ "${#WT_COMPUTERS[@]}" -eq 0 ] && _first_run=1

  _me=$WT_THIS
  _rest=()
  for _c in ${WT_COMPUTERS[@]+"${WT_COMPUTERS[@]}"}; do
    [ "$_c" = "$WT_THIS" ] || _rest+=("$_c")
  done

  # Nothing configured yet: ask for a COUNT and then that many names. "One per
  # line, blank line when there are no more" made people guess both how to
  # finish and whether a blank meant cancel.
  if [ "$_first_run" = "1" ]; then
    _me=$(wt_read_name 'What should I call THIS computer?' "$(wt_default_this)")
    _n=-1
    while [ "$_n" -lt 0 ]; do
      _a=$(menu_read_line '  How many OTHER computers are plugged into these monitors?' 1) || menu_eof
      case $_a in
        ''|*[!0-9]*) printf '  A number, please (16 at most).\n' >&2 ;;
        *) if [ "$_a" -le 16 ]; then _n=$_a; else printf '  A number, please (16 at most).\n' >&2; fi ;;
      esac
    done
    _rest=()
    _i=1
    while [ "$_i" -le "$_n" ]; do
      if [ "$_n" -eq 1 ]; then _q='What is the other one called?'
      else _q="Name for computer $_i of $_n:"; fi
      _rest+=("$(wt_read_name "$_q" '' "$_me ${_rest[*]+${_rest[*]}}")")
      _i=$(( _i + 1 ))
    done
  fi

  # Then, always, a list to correct. Renaming is the common edit -- a name is
  # typed once and lived with -- so it is what selecting a row does. Removing
  # is a ROW, never a blank answer: enter is what people press, so a blank
  # keeps the name here like at every other prompt (specs/configure.md 5.0).
  while :; do
    menu_reset
    menu_add "$_me" 'this computer'
    for _c in ${_rest[@]+"${_rest[@]}"}; do menu_add "$_c" ''; done
    menu_sep
    _addrow=${#MENU_ITEMS[@]}
    menu_add 'Add another computer' ''
    _removerow=${#MENU_ITEMS[@]}
    menu_add 'Remove a computer' ''
    [ "${#_rest[@]}" -eq 0 ] && menu_disable "$_removerow"
    _donerow=${#MENU_ITEMS[@]}
    menu_add 'Done' ''

    printf '\n' >&2
    select_one --default "$_donerow" --escapable \
               --help '  Pick a name to change it, or Done.'
    _pick=$MENU_PICK
    [ "$_pick" -lt 0 ] && break
    [ "$_pick" -eq "$_donerow" ] && break

    if [ "$_pick" -eq "$_addrow" ]; then
      _rest+=("$(wt_read_name 'Name for the new computer' '' "$_me ${_rest[*]+${_rest[*]}}")")
    elif [ "$_pick" -eq "$_removerow" ]; then
      wt_remove_computer ${_rest[@]+"${_rest[@]}"}
      _rest=("${WT_REMAINING[@]+${WT_REMAINING[@]}}")
    elif [ "$_pick" -eq 0 ]; then
      _new=$(wt_read_name 'What should I call THIS computer?' "$_me" "${_rest[*]+${_rest[*]}}")
      wt_maps_edit map_rename "$_me" "$_new"
      _me=$_new
    else
      _idx=$(( _pick - 1 ))
      _victim=${_rest[$_idx]}
      _others=''
      for _c in ${_rest[@]+"${_rest[@]}"}; do [ "$_c" = "$_victim" ] || _others="$_others $_c"; done
      _new=$(wt_read_name "New name for '$_victim'" "$_victim" "$_me$_others")
      wt_maps_edit map_rename "$_victim" "$_new"
      _rest[_idx]=$_new
    fi
  done

  WT_THIS=$_me
  WT_COMPUTERS=("$_me" ${_rest[@]+"${_rest[@]}"})
}

# Carry a rename or a removal into every panel's map THE MOMENT IT HAPPENS,
# rather than making someone answer the monitors again -- re-asking threw away
# answers nobody asked to change. Adding a computer leaves the maps alone; the
# Monitors row then shows which panels do not know about it yet.
#
# Applied as it happens, not inferred afterwards: lining the old list up
# against the new one to work out what changed went wrong the moment one
# sitting held both a rename and a removal, because the removal shifted every
# position after it and the wrong computer was renamed.
#
# An edit that changes a map invalidates a monitor-input pass: the values that
# passed are no longer the values configured. One that changes nothing -- a
# rename to the same name, a removal of a computer no panel has -- does not.
wt_maps_edit() {
  local _fn _i _was
  _fn=$1; shift
  _i=0
  while [ "$_i" -lt "${#WT_A_MAP[@]}" ]; do
    _was=${WT_A_MAP[$_i]}
    WT_A_MAP[_i]=$("$_fn" "$_was" "$@")
    [ "${WT_A_MAP[$_i]}" = "$_was" ] || WT_RAN_DISPLAYS=''
    _i=$(( _i + 1 ))
  done
}

# specs/configure.md 5.3. The other computers, as a list to remove from; the
# survivors are left in WT_REMAINING once Done or esc is chosen. Not a printed
# result, because a command substitution is a subshell and the map edits made
# here would be lost in it. This computer is never offered: its name is what
# `pull` resolves, and a config without it is one the switcher declines to act
# on.
WT_REMAINING=()
wt_remove_computer() {
  local _rest _c _i _on _donerow _pick _victim _next
  _rest=("$@")
  while [ "${#_rest[@]}" -gt 0 ]; do
    menu_reset
    for _c in "${_rest[@]}"; do
      # Which panels lose an input if this one goes -- said in the value column,
      # so the cost is visible BEFORE the row is chosen, not only after.
      _on=$(_i=0
            while [ "$_i" -lt "${#WT_A_MAP[@]}" ]; do
              map_has "${WT_A_MAP[$_i]}" "$_c" && printf '%s\n' "${WT_A_LABEL[$_i]}"
              _i=$(( _i + 1 ))
            done | tk_join_names)
      if [ -n "$_on" ]; then menu_add "$_c" "on $_on"
      else menu_add "$_c" 'not on any monitor'; fi
    done
    menu_sep
    _donerow=${#MENU_ITEMS[@]}
    menu_add 'Done' ''

    printf '\n--- remove a computer ---\n' >&2
    printf '  Removing a computer also clears its input on every monitor it is on.\n\n' >&2
    select_one --default "$_donerow" --escapable
    _pick=$MENU_PICK
    [ "$_pick" -lt 0 ] && break
    [ "$_pick" -eq "$_donerow" ] && break

    _victim=${_rest[$_pick]}
    printf '\n  Its input on every monitor is cleared too. Nothing else changes.\n' >&2
    # Defaults to NO. This is the destructive half of the menu, and the whole
    # reason removal stopped being a blank answer.
    read_yesno "  Remove '$_victim'?" n || continue
    wt_maps_edit map_del "$_victim"
    _next=()
    for _c in "${_rest[@]}"; do [ "$_c" = "$_victim" ] || _next+=("$_c"); done
    _rest=("${_next[@]+${_next[@]}}")
  done
  WT_REMAINING=("${_rest[@]+${_rest[@]}}")
}

# A sensible name for this computer, before anyone has said one. The host name
# is what people already call it, and it is never typed in anger -- `pull` is
# the verb.
wt_default_this() {
  local _n
  _n=$(config_this_computer)
  [ -n "$_n" ] && { printf '%s\n' "$_n"; return; }
  _n=$(wt_format_name "$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo mac)")
  [ -n "$_n" ] && { printf '%s\n' "$_n"; return; }
  printf 'mac\n'
}

# --- inputs ------------------------------------------------------------------

# The inputs to offer for a panel: the channel's own value set, in the channel's
# OWN ORDER, plus any value already assigned that the channel does not list.
#
# It used to put assigned computers' names at the FRONT, replacing the input's
# name -- so answering for the second computer showed "pc  0x11" where "HDMI 1
# 0x11" had been, and the rows moved under you. The monitor's own menu says
# HDMI 1; that is the only label worth showing, and it should stay where it was.
IT_NAMES=(); IT_VALUES=()
wt_input_table() {
  local _method _map _di _i _val _seen _known _old _e
  _method=$1 _map=${2:-}
  IT_NAMES=(); IT_VALUES=()

  _di=-1
  _i=0
  while [ "$_i" -lt "${#DIALECT_METHOD[@]}" ]; do
    [ "${DIALECT_METHOD[$_i]}" = "$_method" ] && _di=$_i
    _i=$(( _i + 1 ))
  done

  if [ "$_di" -ge 0 ]; then
    _old=$IFS; IFS=,
    for _e in ${DIALECT_INPUTS[$_di]}; do
      IFS=$_old
      IT_NAMES+=("${_e%%=*}"); IT_VALUES+=("${_e#*=}")
      IFS=,
    done
    IFS=$_old
  else
    IT_NAMES=("${MCCS_NAMES[@]}"); IT_VALUES=("${MCCS_VALUES[@]}")
  fi

  # A value someone typed by hand is not in the channel's list, and would
  # otherwise be invisible -- including to the "already assigned" marking.
  for _val in $(map_values "$_map"); do
    _seen=0
    for _known in "${IT_VALUES[@]}"; do
      [ "$(tk_lower "$_known")" = "$(tk_lower "$_val")" ] && _seen=1
    done
    [ "$_seen" = "0" ] && { IT_NAMES+=("$_val"); IT_VALUES+=("$_val"); }
  done
}

# Ask which input something is on, for one panel. Prints the value, or nothing
# when --allow-none is given and that computer is not on this panel at all.
WT_INPUT_VALUE=''
WT_INPUT_NONE=0
wt_read_input() {
  local _method _map _prompt _sub _default _forwhom _allownone _now _row _i _v
  local _holder _typerow _nonerow _pick _typed
  _method=$1 _map=$2 _prompt=$3 _sub=$4 _default=$5 _forwhom=$6 _allownone=$7

  WT_INPUT_NONE=0
  wt_input_table "$_method" "$_map"

  printf '\n  %s\n' "$_prompt" >&2
  [ -n "$_sub" ] && printf '  %s\n' "$_sub" >&2

  while :; do
    menu_reset
    _now=-1
    _row=0
    _i=0
    while [ "$_i" -lt "${#IT_NAMES[@]}" ]; do
      _v=${IT_VALUES[$_i]}
      _holder=$(map_who_has "$_map" "$_v")
      # Two computers cannot share a socket, so an assigned input is not merely
      # discouraged -- it is not an answer. It stays in place, says who has it,
      # and the cursor skips it.
      if [ -n "$_holder" ] && [ "$_holder" != "$_forwhom" ]; then
        menu_add "${IT_NAMES[$_i]}" "$_v   assigned to $_holder"
        menu_disable "$_i"
      else
        menu_add "${IT_NAMES[$_i]}" "$_v"
      fi
      if [ -n "$_default" ] && [ "$(tk_lower "$_v")" = "$(tk_lower "$_default")" ]; then
        _row=$_i; _now=$_i
      fi
      _i=$(( _i + 1 ))
    done
    _typerow=${#MENU_ITEMS[@]}
    menu_add 'Type a value...' ''
    _nonerow=-1
    if [ "$_allownone" = "1" ]; then
      _nonerow=${#MENU_ITEMS[@]}
      menu_add 'Not on this monitor' ''
    fi

    # Start on the configured value's row, so a re-run is a review rather than a
    # re-entry. An unlisted value starts on "type a value", which is where it
    # came from; a computer with no answer yet starts on "not on this monitor".
    if [ -z "$_default" ]; then
      if [ "$_allownone" = "1" ]; then _row=$_nonerow; else _row=$_typerow; fi
    elif [ "$_now" -lt 0 ]; then
      _row=$_typerow
    fi
    menu_is_disabled "$_row" && _row=$_typerow

    select_one --default "$_row" --current "$_now"
    _pick=$MENU_PICK

    if [ "$_pick" = "$_nonerow" ] && [ "$_allownone" = "1" ]; then
      WT_INPUT_NONE=1; WT_INPUT_VALUE=''; return 0
    fi
    if [ "$_pick" = "$_typerow" ]; then
      _typed=$(menu_read_line '  Value (e.g. 0x11)' "$_default") || menu_eof
      if ! config_to_byte "$_typed" >/dev/null; then
        printf '  Not a byte.\n' >&2
        continue
      fi
      _v=$_typed
    else
      _v=${IT_VALUES[$_pick]}
    fi

    # Two computers on one input makes `to` ambiguous, and the switcher refuses
    # rather than guess -- so refuse HERE instead, where the person can still
    # say which one they meant. Marking it in the list was not enough: a typed
    # value can still reach it.
    _holder=$(map_who_has "$_map" "$_v")
    if [ -n "$_holder" ] && [ "$_holder" != "$_forwhom" ]; then
      printf '  %s is already %s on this monitor. Two computers cannot share one input.\n' \
             "$_v" "$_holder" >&2
      continue
    fi
    WT_INPUT_VALUE=$_v
    return 0
  done
}

# --- monitors ----------------------------------------------------------------

# Which method to use on a panel whose vendor has a documented alternative.
#
# OFFERED UP FRONT, not only after standard has failed. Someone who already
# knows their model needs the alternative should not have to run a check that
# moves a panel and sends packets purely in order to fail -- and someone who
# knows they need it, watches standard fail, and has not been told the
# alternative exists may reasonably decide the tool does not know about it.
#
# This changes WHEN the choice is offered and nothing else. Values still come
# only from the documented table or from what the user types in that moment;
# nothing is probed, swept or guessed; and the transport gate still refuses a
# manufacturer channel to a panel whose EDID vendor does not match. See
# AGENTS.md hard rule 1b, amended for this, and specs/configure.md section 6.2.
#
# Standard stays the default and stays where the cursor starts.
wt_choose_method() {
  local _di _current _what _alt _now _default
  _di=$1 _current=$2
  _what=${DIALECT_WHAT[$_di]}
  _alt=${DIALECT_METHOD[$_di]}

  printf '\n--- how to talk to this monitor ---\n' >&2
  printf '  Nearly every monitor takes the standard method, including most %s ones.\n' "$_what" >&2
  printf '  A few %s models ignore it and need %s'"'"'s own method instead.\n\n' "$_what" "$_what" >&2
  printf '  If you are not sure, take the standard one. If it turns out not to\n' >&2
  printf '  work, the check further down will offer you this again.\n' >&2

  menu_reset
  menu_add 'Standard' 'what nearly every monitor takes'
  menu_add "$_what's own method" "for $_what models that ignore the standard one"

  _now=-1
  if [ "$_current" = "standard" ]; then _now=0
  elif [ "$_current" = "$_alt" ]; then _now=1; fi
  _default=0
  [ "$_now" -ge 0 ] && _default=$_now

  select_one --default "$_default" --current "$_now" --escapable
  case $MENU_PICK in
    0) printf 'standard\n' ;;
    1) printf '%s\n' "$_alt" ;;
    *) printf '%s\n' "$_current" ;;   # esc: change nothing
  esac
}

# One display: identity is already known; what we need from the human is whether
# to manage it, what to call it, and which input each computer is on.
#
# MACHINES-MAJOR, not inputs-major: a panel has eight possible inputs and two
# real ones. Standard DDC/CI is the answer for everyone here, whatever the make;
# a manufacturer dialect is only reached for later, if the check shows standard
# does not work.
wt_display_answers() {
  local _fi _key _desc _ai _defaultlabel _method _prior _label _map _c _was
  local _sub _allownone _di
  _fi=$1
  _key=${WT_F_KEY[$_fi]}
  _desc=${WT_F_NAME[$_fi]}

  printf '\n  %s   EDID %s   %s\n' "$_desc" "$_key" "${WT_F_MFG[$_fi]}" >&2

  if _ai=$(wt_answer_index "$_key"); then
    _defaultlabel=${WT_A_LABEL[$_ai]}
    _method=${WT_A_METHOD[$_ai]}
    _prior=${WT_A_MAP[$_ai]}
  else
    _defaultlabel=$(wt_format_name "$(printf '%s' "$_desc" | awk '{print $1}')")
    [ -n "$_defaultlabel" ] || _defaultlabel=$(tk_lower "${WT_F_MFG[$_fi]}")
    # An existing method is a settled answer -- it was proven by someone
    # watching the screen. Every panel starts on standard.
    _method=standard
    _prior=''
  fi

  if ! read_yesno '  Manage this monitor?' y; then
    # "No" is DESTRUCTIVE when there is something to lose: it forgets which
    # computer is on which input. "Manage" reads like a flag, so the loss is
    # named and confirmed -- the same rule as removing a computer
    # (specs/configure.md 5.3), and the symmetry worth having between the two
    # menus. A panel with nothing configured has nothing to lose and is not
    # asked twice.
    if [ "$(map_count "$_prior")" -gt 0 ]; then
      printf '\n  Which computer is on which of its inputs is forgotten. Nothing else\n' >&2
      printf '  changes, and nothing is written until you save.\n' >&2
      read_yesno '  Stop managing this monitor?' n || { printf 'KEEP\n'; return 0; }
    fi
    printf 'REMOVE\n'
    return 0
  fi

  _label=$(menu_read_line '  Short name for it' "$_defaultlabel") || menu_eof
  _label=$(wt_format_name "$_label")
  [ -n "$_label" ] || _label=$_defaultlabel

  # BEFORE the inputs, because which values are on offer depends on the answer.
  if _di=$(wt_dialect_for "$(printf '%s' "$_key" | cut -d: -f1)"); then
    _method=$(wt_choose_method "$_di" "$_method")
  fi

  _map=''
  for _c in "${WT_COMPUTERS[@]}"; do
    _was=$(map_get "$_prior" "$_c")
    _sub=''
    _allownone=1
    if [ "$_c" = "$WT_THIS" ]; then
      _sub='(this computer -- the input you would pick to see this screen)'
      _allownone=0
    fi
    wt_read_input "$_method" "$_map" \
      "On the $_desc, which input is '$_c' on?" "$_sub" "$_was" "$_c" "$_allownone"
    [ "$WT_INPUT_NONE" = "1" ] || _map=$(map_set "$_map" "$_c" "$WT_INPUT_VALUE")
  done

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_key" "$_label" "$_desc" "$_method" "${WT_F_VENDOR[$_fi]}|${WT_F_PRODUCT[$_fi]}" "$_map"
}

# The monitors, as a list you pick from -- the same shape as the computers list,
# and for the same reason. Walking every panel in sequence to change one value
# meant answering for all of them, which is what a menu exists to avoid.
wt_monitors() {
  local _i _ai _donerow _land _pick _before _row _key
  while :; do
    menu_reset
    _i=0
    while [ "$_i" -lt "${#WT_F_KEY[@]}" ]; do
      if _ai=$(wt_answer_index "${WT_F_KEY[$_i]}"); then
        menu_add "${WT_F_NAME[$_i]}" "$(printf '%s: %s' "${WT_A_LABEL[$_ai]}" \
                    "$(map_computers "${WT_A_MAP[$_ai]}" | paste -sd/ -)")"
      else
        menu_add "${WT_F_NAME[$_i]}" 'not managed'
      fi
      _i=$(( _i + 1 ))
    done
    menu_sep
    _donerow=${#MENU_ITEMS[@]}
    menu_add 'Done' ''

    # The first panel nobody has answered for, else the way out.
    _land=$_donerow
    _i=0
    while [ "$_i" -lt "${#WT_F_KEY[@]}" ]; do
      if ! wt_answer_index "${WT_F_KEY[$_i]}" >/dev/null; then _land=$_i; break; fi
      _i=$(( _i + 1 ))
    done

    printf '\n--- monitors ---\n' >&2
    printf 'Which of these should follow the switch, and which input is each\n' >&2
    printf 'computer on?\n\n' >&2
    select_one --default "$_land" --escapable
    _pick=$MENU_PICK
    [ "$_pick" -lt 0 ] && return 0
    [ "$_pick" -eq "$_donerow" ] && return 0

    _before=$(wt_answers_signature)
    _row=$(wt_display_answers "$_pick")
    # Declining to stop managing it: nothing was answered, so nothing changes.
    [ "$_row" = "KEEP" ] && continue
    _key=${WT_F_KEY[$_pick]}
    wt_answer_remove "$_key"
    if [ "$_row" != "REMOVE" ]; then wt_answer_add "$_row"; fi
    # A pass belongs to the values that passed. Carrying it across an edit would
    # show "all responded" beside numbers nothing tried -- but looking at the
    # list and changing nothing is not an edit.
    [ "$_before" != "$(wt_answers_signature)" ] && WT_RAN_DISPLAYS=''
  done
}

wt_answers_signature() {
  local _i _s
  _i=0 _s=''
  while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do
    _s="$_s|${WT_A_LABEL[$_i]}=${WT_A_METHOD[$_i]}=${WT_A_MAP[$_i]}"
    _i=$(( _i + 1 ))
  done
  printf '%s\n' "$_s"
}

wt_answer_remove() {
  local _k _K _L _N _M _V _P _MP _i
  _k=$1
  _K=(); _L=(); _N=(); _M=(); _V=(); _P=(); _MP=()
  _i=0
  while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do
    if [ "${WT_A_KEY[$_i]}" != "$_k" ]; then
      _K+=("${WT_A_KEY[$_i]}"); _L+=("${WT_A_LABEL[$_i]}"); _N+=("${WT_A_NAME[$_i]}")
      _M+=("${WT_A_METHOD[$_i]}"); _V+=("${WT_A_VENDOR[$_i]}"); _P+=("${WT_A_PRODUCT[$_i]}")
      _MP+=("${WT_A_MAP[$_i]}")
    fi
    _i=$(( _i + 1 ))
  done
  WT_A_KEY=("${_K[@]+${_K[@]}}"); WT_A_LABEL=("${_L[@]+${_L[@]}}"); WT_A_NAME=("${_N[@]+${_N[@]}}")
  WT_A_METHOD=("${_M[@]+${_M[@]}}"); WT_A_VENDOR=("${_V[@]+${_V[@]}}")
  WT_A_PRODUCT=("${_P[@]+${_P[@]}}"); WT_A_MAP=("${_MP[@]+${_MP[@]}}")
}

wt_answer_add() {
  local _old
  _old=$IFS; IFS=$(printf '\t')
  # shellcheck disable=SC2086
  set -- $1
  IFS=$_old
  WT_A_KEY+=("$1"); WT_A_LABEL+=("$2"); WT_A_NAME+=("$3"); WT_A_METHOD+=("$4")
  WT_A_VENDOR+=("${5%%|*}"); WT_A_PRODUCT+=("${5#*|}"); WT_A_MAP+=("${6:-}")
}

# --- triggers ----------------------------------------------------------------

wt_triggers() {
  local _keys _labels _details _kind _key _state _name _checked _i _d _new _n
  printf '\n--- triggers ---\n' >&2
  printf 'Which devices move to this computer when you flip the switch?\n' >&2
  printf 'USB rows are attached right now; Bluetooth rows are everything paired.\n\n' >&2

  _keys=() _labels=() _details=()
  while IFS='|' read -r _kind _key _state _name; do
    [ -n "$_key" ] || continue
    _keys+=("$_key")
    _labels+=("$(printf '%-20s %-4s' "$_key" "$(printf '%s' "$_kind" | tr '[:lower:]' '[:upper:]')")")
    _details+=("$_name  ($_state)")
  done <<EOF
$("$TK_WATCHER" --list 2>/dev/null || true)
EOF

  if [ "${#_keys[@]}" -eq 0 ]; then
    printf '  No devices found.\n' >&2
    return 0
  fi

  menu_reset
  _checked=''
  _i=0
  while [ "$_i" -lt "${#_keys[@]}" ]; do
    menu_add "${_labels[$_i]}" "${_details[$_i]}"
    for _d in ${WT_DEVICES[@]+"${WT_DEVICES[@]}"}; do
      [ "$_d" = "${_keys[$_i]}" ] && _checked="$_checked $_i"
    done
    _i=$(( _i + 1 ))
  done

  select_many --checked "$_checked" --escapable \
    --help '  Keyboards and mice often share a vendor id with something that never
  moves. The full vendor+product is matched, so pick the exact rows.'

  [ "$MENU_ESCAPED" = "1" ] && return 0
  _new=()
  for _n in $MENU_PICKED; do _new+=("${_keys[$_n]}"); done
  WT_DEVICES=("${_new[@]+${_new[@]}}")
  WT_RAN_TRIGGERS=''
}

# --- autostart ---------------------------------------------------------------

# From boot is offered FIRST and is the default, because a computer sitting at a
# login screen should still follow the switch. The cost is one sudo prompt
# during setup, and asking for it once beats discovering months later that
# switching quietly does nothing until you log in.
#
# It runs AS THE USER, UNELEVATED -- a LaunchDaemon with UserName set. Root
# installs it into the system domain; root does not run it. That is the same
# property the Windows tier has, and the tier would not be worth having without
# it: nothing elevated may run on the switch path.
#
# This row was disabled for a while, reading "not available on macOS -- needs
# root", on two claims that were both measured wrong. A LaunchDaemon with
# UserName does not run as root; and reading the displays does not need a
# logged-in session -- IOKit identity, m1ddc and a full `pull` were all measured
# working from a LaunchDaemon with no session at all. See specs/CHANGELOG.md
# revision 4.
wt_tier() {
  local _now _default
  printf '\n--- should it start on its own? ---\n' >&2
  printf '  It can start as soon as the computer starts, or after you log in for\n' >&2
  printf '  the first time. Starting before you log in needs your password once,\n' >&2
  printf '  now, to install it. Nothing runs as an administrator afterwards.\n\n' >&2
  printf '  Answering no still installs and starts it now; it just will not come\n' >&2
  printf '  back after a restart until you run:  trigger-kvm restart\n\n' >&2

  menu_reset
  menu_add 'From boot' 'needs your password once, to install'
  menu_add 'From login' 'no password needed'
  menu_add 'No -- I will start it myself' ''

  _now=-1
  case $WT_TIER in boot) _now=0 ;; login) _now=1 ;; no) _now=2 ;; esac
  _default=0
  [ "$_now" -ge 0 ] && _default=$_now

  select_one --default "$_default" --current "$_now" --escapable
  [ "$MENU_PICK" -lt 0 ] && return 0
  case $MENU_PICK in
    0) WT_TIER=boot ;;
    1) WT_TIER=login ;;
    2) WT_TIER=no ;;
  esac
}

# --- PATH --------------------------------------------------------------------

wt_path() {
  local _now _default
  printf '\n--- PATH ---\n' >&2
  printf '  Add %s to your PATH, so `trigger-kvm` works from anywhere?\n' "$TK_BINDIR" >&2
  printf '  Only that directory is added, and it holds only the launcher.\n\n' >&2

  menu_reset
  menu_add 'Yes' 'trigger-kvm works from anywhere'
  menu_add 'No'  'call it by its full path'

  _now=-1
  case $WT_WANTPATH in yes) _now=0 ;; no) _now=1 ;; esac
  _default=0
  [ "$_now" -ge 0 ] && _default=$_now

  select_one --default "$_default" --current "$_now" --escapable
  [ "$MENU_PICK" -lt 0 ] && return 0
  case $MENU_PICK in 0) WT_WANTPATH=yes ;; 1) WT_WANTPATH=no ;; esac
}

# --- writing -----------------------------------------------------------------

wt_write_config() {
  local _path _i _l _c
  _path=$1
  mkdir -p "$(dirname "$_path")"
  {
    echo '# trigger-kvm configuration'
    echo '#'
    echo '# Written by `trigger-kvm configure`. Safe to edit by hand.'
    echo '#'
    echo '# Everything here is read at the point it is used, so there is no separate'
    echo '# apply step: display edits take effect on the next switch, and trigger edits'
    echo '# when the watcher next starts --  trigger-kvm restart'
    echo '#'
    echo '# Displays are identified by the EDID read off the output, never by an index'
    echo '# -- display numbering is not stable. See what is attached with:'
    echo '#   trigger-kvm list'
    echo ''
    echo '# --- install ----------------------------------------------------------'
    printf 'install.autostart = %s\n' "${WT_TIER:-login}"
    echo ''
    echo '# --- computers --------------------------------------------------------'
    echo '# What this computer is called below. `trigger-kvm pull` means "point every'
    echo '# display at this one"; `trigger-kvm to mac` names any other.'
    echo ''
    printf 'computer.this = %s\n' "$WT_THIS"
    echo ''
    echo '# --- displays ---------------------------------------------------------'
    echo '# method: standard (I2C src 0x51, VCP 0x60) -- what nearly every panel takes'
    echo '#         lg-alt   (src 0x50, VCP 0xF4) -- LG panels whose 0x60 is stubbed'
    echo '# input.<value> = <computer>: which computer is on which input of that panel.'
    echo '#         This is the whole map. pull and to are the same lookup against it,'
    echo '#         differing only in which name they look up, so the two can never'
    echo '#         disagree about where a computer is.'
    echo ''
    _i=0
    while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do
      _l=${WT_A_LABEL[$_i]}
      printf 'display.%s.vendor  = %s\n' "$_l" "${WT_A_VENDOR[$_i]}"
      printf 'display.%s.product = %s\n' "$_l" "${WT_A_PRODUCT[$_i]}"
      printf 'display.%s.name    = %s\n' "$_l" "${WT_A_NAME[$_i]}"
      printf 'display.%s.method  = %s\n' "$_l" "${WT_A_METHOD[$_i]}"
      for _c in $(map_computers "${WT_A_MAP[$_i]}"); do
        printf 'display.%s.input.%s = %s\n' "$_l" \
          "$(tk_lower "$(map_get "${WT_A_MAP[$_i]}" "$_c")")" "$_c"
      done
      echo ''
      _i=$(( _i + 1 ))
    done
    echo '# --- triggers ---------------------------------------------------------'
    echo '#'
    echo '# A trigger is anything that runs:  trigger-kvm pull'
    echo '# The one shipped here watches device presence. A hotkey or a Stream Deck'
    echo '# button needs no support from this tool -- it just runs that command.'
    echo '#'
    echo '# Triggers run `pull` and nothing else. Never wire one to another computer:'
    echo '# a name like `pc` describes inputs on hardware this computer cannot observe,'
    echo '# and a stale one would then be able to cause an AUTOMATIC switch to a dead'
    echo '# input. Getting there by hand, watching, is a different risk entirely.'
    echo '#'
    echo '# device: usb:VVVV:PPPP (bare VVVV:PPPP means usb) or bt:AAAAAAAAAAAA.'
    echo '#         Bluetooth fires on CONNECTED, and every PAIRED device is offered.'
    echo ''
    printf 'trigger.device   = %s\n' "$(printf '%s' "${WT_DEVICES[*]+${WT_DEVICES[*]}}" | sed 's/ /, /g')"
    printf 'trigger.debounce = %s\n' "$(wt_keep 'trigger.debounce' '3.0')"
    printf 'trigger.settle   = %s\n' "$(wt_keep 'trigger.settle' '0.75')"
    echo ''
  } > "$_path"
}

# A hand-written value the walkthrough never asks about survives a rewrite.
wt_keep() {
  local _v
  _v=$(config_get "$1")
  if [ -n "$_v" ]; then printf '%s\n' "$_v"; else printf '%s\n' "$2"; fi
}

# --- the menu IS the flow ----------------------------------------------------

WT_RAN_DISPLAYS=''
WT_RAN_TRIGGERS=''
WT_DISPLAYS_OK=0
WT_TRIGGERS_OK=0

# The walkthrough. Current settings pre-fill everything, so a re-run is a review
# rather than a replay -- unless --fresh, which starts from nothing.
#
# Two distinct roles for the old config, and --fresh separates them: it supplies
# DEFAULTS, and it holds values that must SURVIVE. Dropping both would silently
# discard anything hand-written, so --fresh clears the first and never touches
# the second.
cmd_configure() {
  local _fresh _isfirst _i _c _d _pathrow _claims _disprow _trigrow _saverow
  local _land _pick _missing
  _fresh=0
  [ "${1:-}" = "--fresh" ] && _fresh=1

  _isfirst=1
  [ -f "$CONFIG" ] && _isfirst=0

  # Said HERE as well as in `status`: configure is where a stale install shows
  # up, as a row that is missing or wrong.
  tk_warn_if_stale

  printf '\n==============================================================\n' >&2
  if [ "$_isfirst" = "1" ]; then printf ' trigger-kvm setup\n' >&2
  else printf ' trigger-kvm reconfigure\n' >&2; fi
  printf '==============================================================\n' >&2
  if [ "$_fresh" = "1" ] && [ "$_isfirst" = "0" ]; then
    printf ' Starting fresh -- nothing is pre-filled from the current setup.\n' >&2
  elif [ "$_isfirst" = "0" ]; then
    printf ' Current settings are the defaults -- press enter to keep one.\n' >&2
  fi

  wt_load_found
  if [ "${#WT_F_KEY[@]}" -eq 0 ]; then
    tk_log 'no external displays found -- nothing to configure.'
    exit 2
  fi

  printf '\n--- monitors found (%s) ---\n' "${#WT_F_KEY[@]}" >&2
  _i=0
  while [ "$_i" -lt "${#WT_F_KEY[@]}" ]; do
    printf '  %-24s EDID %s\n' "${WT_F_NAME[$_i]}" "${WT_F_KEY[$_i]}" >&2
    _i=$(( _i + 1 ))
  done

  # --fresh clears the SEED. What must survive is re-read at write time.
  if [ "$_fresh" = "1" ]; then
    WT_THIS=''; WT_COMPUTERS=(); WT_DEVICES=(); WT_TIER=''
    WT_A_KEY=(); WT_A_LABEL=(); WT_A_NAME=(); WT_A_METHOD=()
    WT_A_VENDOR=(); WT_A_PRODUCT=(); WT_A_MAP=()
  else
    WT_THIS=$(config_this_computer)
    WT_COMPUTERS=()
    if [ -n "$WT_THIS" ]; then WT_COMPUTERS+=("$WT_THIS"); fi
    for _c in $(config_known_computers); do
      [ "$_c" = "$WT_THIS" ] || WT_COMPUTERS+=("$_c")
    done
    [ -n "$WT_THIS" ] || WT_COMPUTERS=()
    wt_load_answers
    WT_DEVICES=()
    for _d in $(config_trigger_devices); do WT_DEVICES+=("$_d"); done
    case $(config_get 'install.autostart') in
      boot)  WT_TIER=boot ;;
      login) WT_TIER=login ;;
      no)    WT_TIER=no ;;
      *)     WT_TIER='' ;;
    esac
  fi

  WT_ONPATH=0
  case ":$PATH:" in *":$TK_BINDIR:"*) WT_ONPATH=1 ;; esac
  WT_WANTPATH=''

  while :; do
    menu_reset

    # ONE PUNCTUATION RULE down the value column, because it is read as a
    # column: ", " separates items, ": " separates a label from its value, "/"
    # joins things sharing one label. Not cosmetic -- the wrapper breaks at
    # ", ", so a row using anything else cannot wrap.
    if [ "${#WT_COMPUTERS[@]}" -eq 0 ]; then _d='not set'; else
      _d=''
      for _c in "${WT_COMPUTERS[@]}"; do
        if [ "$_c" = "$WT_THIS" ]; then _d="$_d, $_c (this)"; else _d="$_d, $_c"; fi
      done
      _d=${_d#, }
    fi
    menu_add 'Computers' "$_d"

    if [ "${#WT_A_KEY[@]}" -eq 0 ]; then _d='not set'; else
      _d=''
      _i=0
      while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do
        _d="$_d, ${WT_A_LABEL[$_i]}: $(map_computers "${WT_A_MAP[$_i]}" | paste -sd/ -)"
        _i=$(( _i + 1 ))
      done
      _d=${_d#, }
    fi
    menu_add 'Monitors' "$_d"

    if [ "${#WT_DEVICES[@]}" -eq 0 ]; then _d='not set'
    else _d=$(printf '%s' "${WT_DEVICES[*]}" | sed 's/ /, /g'); fi
    menu_add 'Triggers' "$_d"

    # NOTHING IS PRESET. Autostart and PATH have obvious answers, but the
    # suggestion belongs on the highlighted row INSIDE their menu, not in the
    # value column of a menu nobody has opened. One of those answers edits a
    # PATH; showing an answer nobody gave is the tool answering on their behalf.
    case $WT_TIER in
      boot)  _d='from boot' ;;
      login) _d='from login' ;;
      no)    _d='no' ;;
      *)     _d='not set' ;;
    esac
    menu_add 'Autostart?' "$_d"

    # ALWAYS DRAWN, even when there is nothing to decide. Hiding it moved every
    # row below it and left the cursor apparently skipping a step, with no way
    # to tell whether PATH had been handled or forgotten.
    _pathrow=${#MENU_ITEMS[@]}
    if [ "$WT_ONPATH" = "1" ]; then _d='already on PATH'
    elif [ -z "$WT_WANTPATH" ]; then _d='not set'
    else _d=$WT_WANTPATH; fi
    menu_add 'Add to PATH?' "$_d"
    [ "$WT_ONPATH" = "1" ] && menu_disable "$_pathrow"

    menu_sep

    # "the monitor inputs", not "the monitors": what is under test is the claim
    # that input V of panel P is computer C. A panel that answers every command
    # perfectly while its inputs are mapped to the wrong computers fails this
    # and is not broken.
    _claims=0
    _i=0
    while [ "$_i" -lt "${#WT_A_MAP[@]}" ]; do
      for _c in $(map_computers "${WT_A_MAP[$_i]}"); do
        [ "$_c" = "$WT_THIS" ] || _claims=$(( _claims + 1 ))
      done
      _i=$(( _i + 1 ))
    done
    _disprow=${#MENU_ITEMS[@]}
    if [ "$_claims" -eq 1 ]; then menu_add 'Test the monitor input' "${WT_RAN_DISPLAYS:-untested}"
    else menu_add 'Test the monitor inputs' "${WT_RAN_DISPLAYS:-untested}"; fi
    _trigrow=${#MENU_ITEMS[@]}
    if [ "${#WT_DEVICES[@]}" -eq 1 ]; then menu_add 'Test the trigger' "${WT_RAN_TRIGGERS:-untested}"
    else menu_add 'Test the triggers' "${WT_RAN_TRIGGERS:-untested}"; fi

    menu_sep
    _saverow=${#MENU_ITEMS[@]}
    menu_add 'Save configuration and run' ''
    menu_add 'Cancel (discard changes)' ''

    # Where the cursor lands is the recommendation, and it is just "the next
    # thing that is not done": the unanswered sections in order, then the
    # checks, then Save. A FAILED check sends the cursor to the setting that
    # failed, not onward.
    if   [ "${#WT_COMPUTERS[@]}" -eq 0 ]; then _land=0
    elif [ "${#WT_A_KEY[@]}"     -eq 0 ]; then _land=1
    elif [ "${#WT_DEVICES[@]}"   -eq 0 ]; then _land=2
    elif [ -z "$WT_TIER" ];             then _land=3
    elif [ "$WT_ONPATH" = "0" ] && [ -z "$WT_WANTPATH" ]; then _land=$_pathrow
    elif [ -z "$WT_RAN_DISPLAYS" ];     then _land=$_disprow
    elif [ "$WT_DISPLAYS_OK" = "0" ];   then _land=1
    elif [ -z "$WT_RAN_TRIGGERS" ];     then _land=$_trigrow
    elif [ "$WT_TRIGGERS_OK" = "0" ];   then _land=2
    else _land=$_saverow; fi

    printf '\n' >&2
    if [ "${#WT_A_KEY[@]}" -gt 0 ] && [ "${#WT_DEVICES[@]}" -gt 0 ]; then
      printf -- '--- review configuration ---\n\n' >&2
    else
      printf -- '--- configuration ---\n\n' >&2
    fi

    # esc moves the cursor to Cancel; it does not take it. A setup still cannot
    # be discarded by a stray keypress -- enter on a row that says
    # "Cancel (discard changes)" is still required.
    select_one --default "$_land" --escape-to $(( _saverow + 1 ))
    _pick=$MENU_PICK

    if [ "$_pick" -eq $(( _saverow + 1 )) ]; then
      tk_log 'cancelled; nothing was changed.'
      exit 1
    fi

    if [ "$_pick" -eq "$_saverow" ]; then
      # Saving half a setup would write a config the switcher then refuses to
      # act on, which is a worse way to find out.
      _missing=''
      [ "${#WT_COMPUTERS[@]}" -eq 0 ] && _missing="$_missing
Computers"
      [ "${#WT_A_KEY[@]}"     -eq 0 ] && _missing="$_missing
Monitors"
      [ "${#WT_DEVICES[@]}"   -eq 0 ] && _missing="$_missing
Triggers"
      [ -z "$WT_TIER" ]               && _missing="$_missing
Autostart?"
      if [ "$WT_ONPATH" = "0" ] && [ -z "$WT_WANTPATH" ]; then _missing="$_missing
Add to PATH?"; fi
      if [ -z "$_missing" ]; then break; fi
      printf '\n  Still needed: %s.\n' \
        "$(printf '%s' "${_missing#
}" | tk_join_names)" >&2
      continue
    fi

    case ${MENU_ITEMS[$_pick]} in
      Computers)      wt_computers ;;
      Monitors)       wt_monitors ;;
      Triggers)       wt_triggers ;;
      'Autostart?')   wt_tier ;;
      'Add to PATH?') wt_path ;;
      'Test the monitor input'*) wt_check_displays ;;
      'Test the trigger'*)       wt_check_triggers ;;
    esac
  done

  wt_write_config "$CONFIG"
  tk_log "wrote $CONFIG"
  [ "$WT_WANTPATH" = "yes" ] && wt_add_to_path
  printf '\n' >&2
  tk_log 'configured. Applying...'
  return 0
}

# Put the launcher's directory on PATH by appending one line to the login shell's
# rc file. Only the bin directory, never the program directory: that would
# publish every file in it as a command.
wt_add_to_path() {
  local _rc
  case $SHELL in
    */zsh)  _rc="$HOME/.zshrc" ;;
    */bash) _rc="$HOME/.bash_profile" ;;
    *)      _rc="$HOME/.profile" ;;
  esac
  if [ -f "$_rc" ] && grep -qF "$TK_BINDIR" "$_rc" 2>/dev/null; then
    tk_log "$TK_BINDIR is already named in $_rc"
    return 0
  fi
  {
    echo ''
    echo '# added by trigger-kvm'
    printf 'export PATH="%s:$PATH"\n' "$TK_BINDIR"
  } >> "$_rc"
  tk_log "added $TK_BINDIR to PATH in $_rc (open a new terminal for it to take)"
}
