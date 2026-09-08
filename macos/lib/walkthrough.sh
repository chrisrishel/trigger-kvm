# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers
# shellcheck disable=SC2016  # the backticks below are prose, quoting command names
# shellcheck disable=SC2153  # WT_F is assigned in answers.sh

# The walkthrough: specs/configure.md. THE MENU IS THE FLOW, and nothing is
# written until Save. The state it edits lives in lib/answers.sh.

# --- names -------------------------------------------------------------------

COMPUTER_NAME_RULE='Lowercase letters, digits and dashes.'

# One name per computer: a config value, an argument you type and a label in
# every prompt, so it has to be typeable without quoting.
wt_format_name() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/[[:space:]._]\{1,\}/-/g' \
        -e 's/[^a-z0-9-]//g' \
        -e 's/--*/-/g' \
        -e 's/^-//' -e 's/-$//'
}

# Suggests a corrected name rather than silently mangling one.
wt_read_name() {
  local _prompt _default _taken _what _raw _n
  _prompt=$1 _default=${2:-} _taken=${3:-} _what=${4:-computer}
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
      *" $_n "*)
        # Two literal lines: both are normative wording.
        if [ "$_what" = "monitor" ]; then
          printf '  There is already a monitor called %s.\n' "$_n" >&2
        else
          printf '  There is already a computer called %s.\n' "$_n" >&2
        fi
        continue ;;
    esac
    printf '%s\n' "$_n"
    return 0
  done
}

# The host name, reduced to the character rule.
wt_default_this() {
  local _n
  _n=$(wt_format_name "$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo mac)")
  printf '%s\n' "${_n:-mac}"
}

# --- computers ---------------------------------------------------------------

# Asked BEFORE the monitors, so a computer is described once and every panel
# offers the same names (specs 5).
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

  # First run: a count, then that many names.
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

  # Then, always, the list. Picking a name renames it; removing is a row (5.3).
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

# The other computers as a list to remove from; the survivors are left in
# WT_REMAINING. This computer is never offered: its name is what `pull` resolves.
WT_REMAINING=()
wt_remove_computer() {
  local _rest _c _i _on _donerow _pick _victim _next
  _rest=("$@")
  while [ "${#_rest[@]}" -gt 0 ]; do
    menu_reset
    for _c in "${_rest[@]}"; do
      # The cost, in the value column, before the row is chosen.
      _on=$(_i=0
            while [ "$_i" -lt "${#WT_A[@]}" ]; do
              wt_rec "$_i"
              map_has "$R_MAP" "$_c" && printf '%s\n' "$R_LABEL"
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
    read_yesno "  Remove '$_victim'?" n || continue
    wt_maps_edit map_del "$_victim"
    _next=()
    for _c in "${_rest[@]}"; do [ "$_c" = "$_victim" ] || _next+=("$_c"); done
    _rest=("${_next[@]+${_next[@]}}")
  done
  WT_REMAINING=("${_rest[@]+${_rest[@]}}")
}

# --- inputs ------------------------------------------------------------------

# The inputs to offer for a panel: the channel's own values in the channel's
# own order, plus any assigned value the channel does not list (6.1).
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

  for _val in $(map_values "$_map"); do
    _seen=0
    for _known in "${IT_VALUES[@]}"; do
      [ "$(tk_lower "$_known")" = "$(tk_lower "$_val")" ] && _seen=1
    done
    [ "$_seen" = "0" ] && { IT_NAMES+=("$_val"); IT_VALUES+=("$_val"); }
  done
}

# Ask which input a computer is on, for one panel (6.1). Leaves the value in
# WT_INPUT_VALUE, or sets WT_INPUT_NONE (not on this monitor) or WT_INPUT_ESC.
#
#   wt_read_input method map prompt subtitle default forwhom allownone [escapable]
WT_INPUT_VALUE=''
WT_INPUT_NONE=0
WT_INPUT_ESC=0
wt_read_input() {
  local _method _map _prompt _sub _default _forwhom _allownone _escapable _now _row _i _v
  local _holder _typerow _nonerow _pick _typed _n _esc
  _method=$1 _map=$2 _prompt=$3 _sub=$4 _default=$5 _forwhom=$6 _allownone=$7 _escapable=${8:-0}

  WT_INPUT_NONE=0
  WT_INPUT_ESC=0
  # Canonical 0xNN, so a hand-edited `17` finds its row and collides with 0x11.
  if _n=$(config_to_byte "$_default" 2>/dev/null); then _default=$(printf '0x%02X' "$_n"); fi
  _esc=''
  [ "$_escapable" = "1" ] && _esc=--escapable
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
      # An input another computer has is not an answer: drawn, annotated,
      # skipped.
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

    # The cursor starts on the configured value; an unlisted value on "type";
    # no answer yet on "not on this monitor". Never on a row it cannot choose.
    if [ -z "$_default" ]; then
      if [ "$_allownone" = "1" ]; then _row=$_nonerow; else _row=$_typerow; fi
    elif [ "$_now" -lt 0 ]; then
      _row=$_typerow
    fi
    menu_is_disabled "$_row" && _row=$_typerow

    # shellcheck disable=SC2086  # $_esc is a flag or empty, and must split
    select_one --default "$_row" --current "$_now" $_esc
    _pick=$MENU_PICK

    if [ "$_pick" -lt 0 ]; then
      WT_INPUT_ESC=1; WT_INPUT_VALUE=''; return 0
    fi
    if [ "$_pick" = "$_nonerow" ] && [ "$_allownone" = "1" ]; then
      WT_INPUT_NONE=1; WT_INPUT_VALUE=''; return 0
    fi
    if [ "$_pick" = "$_typerow" ]; then
      if [ "$_method" != "standard" ]; then
        # A typed byte is the one thing that reaches a manufacturer channel
        # from outside the documented table.
        printf "\n  This is the manufacturer's service channel. Type only a value you have\n" >&2
        printf '  from documentation; an unknown value here has made monitors unusable.\n' >&2
      fi
      _typed=$(menu_read_line '  Value (e.g. 0x11)' "$_default") || menu_eof
      if ! _n=$(config_to_byte "$_typed"); then
        printf '  Not a byte.\n' >&2
        continue
      fi
      _v=$(printf '0x%02X' "$_n")
    else
      _v=${IT_VALUES[$_pick]}
    fi

    # Collision is by value, not spelling, and a typed value can reach an
    # assigned input the list disabled.
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

# Which method to use on a panel whose vendor has a documented alternative
# (6.2). Offered up front; standard stays the default. Prints the method, or
# BACK for esc.
wt_choose_method() {
  local _di _current _what _alt _now _default
  _di=$1 _current=$2
  _what=${DIALECT_WHAT[$_di]}
  _alt=${DIALECT_METHOD[$_di]}

  printf '\n--- how to talk to this monitor ---\n' >&2
  printf '  Nearly every monitor takes the standard method, including most %s ones.\n' "$_what" >&2
  printf '  A few %s models ignore it and need %s'"'"'s own method instead.\n\n' "$_what" "$_what" >&2
  printf '  %s'"'"'s own method talks to a service channel on the monitor. It is\n' "$_what" >&2
  printf '  sent only the values written down for it: unknown values on that\n' >&2
  printf '  channel have made monitors unusable.\n\n' >&2
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
    *) printf 'BACK\n' ;;
  esac
}

# Every managed label but this panel's own, for the duplicate check.
wt_labels_except() {
  local _i _out
  _i=0 _out=''
  while [ "$_i" -lt "${#WT_A[@]}" ]; do
    wt_rec "$_i"
    [ "$R_KEY" != "$1" ] && _out="$_out $R_LABEL"
    _i=$(( _i + 1 ))
  done
  printf '%s\n' "$_out"
}

# One panel's questions, as one submenu (6): manage it, a short name, the
# method where the vendor has one, then each computer's input. Prints the new
# answer record, KEEP (backed out or declined to stop), or REMOVE.
#
#   wt_display_answers key name mfg vendor product attached
wt_display_answers() {
  local _key _desc _mfg _vendor _product _attached _ai _defaultlabel _method _prior
  local _label _map _c _was _sub _allownone _di
  _key=$1 _desc=$2 _mfg=$3 _vendor=$4 _product=$5 _attached=$6

  printf '\n  %s   EDID %s   %s\n' "$_desc" "$_key" "$_mfg" >&2

  if _ai=$(wt_answer_index "$_key"); then
    wt_rec "$_ai"
    _defaultlabel=$R_LABEL
    _method=$R_METHOD
    _prior=$R_MAP
  else
    _defaultlabel=$(wt_format_name "$(printf '%s' "$_desc" | awk '{print $1}')")
    [ -n "$_defaultlabel" ] || _defaultlabel=$(tk_lower "$_mfg")
    # Every panel starts on standard; an existing method is a settled answer.
    _method=standard
    _prior=''
  fi

  if ! read_yesno '  Manage this monitor?' y; then
    # Forgetting which computer is on which input is confirmed when there is
    # something to lose.
    if [ "$(map_count "$_prior")" -gt 0 ]; then
      printf '\n  Which computer is on which of its inputs is forgotten. Nothing else\n' >&2
      printf '  changes, and nothing is written until you save.\n' >&2
      read_yesno '  Stop managing this monitor?' n || { printf 'KEEP\n'; return 0; }
    fi
    printf 'REMOVE\n'
    return 0
  fi

  _label=$(wt_read_name 'Short name for it' "$_defaultlabel" "$(wt_labels_except "$_key")" monitor)

  # Before the inputs: which values are on offer depends on the answer. Esc
  # here or at any input backs out of the whole panel.
  if _di=$(wt_dialect_for "$(printf '%s' "$_key" | cut -d: -f1)"); then
    _was=$_method
    _method=$(wt_choose_method "$_di" "$_method")
    [ "$_method" = "BACK" ] && { printf 'KEEP\n'; return 0; }
    # A changed method clears the map: its values were for the other channel.
    [ "$_method" = "$_was" ] || _prior=''
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
      "On the $_desc, which input is '$_c' on?" "$_sub" "$_was" "$_c" "$_allownone" 1
    [ "$WT_INPUT_ESC" = "1" ] && { printf 'KEEP\n'; return 0; }
    [ "$WT_INPUT_NONE" = "1" ] || _map=$(map_set "$_map" "$_c" "$WT_INPUT_VALUE")
  done

  wt_record "$_key" "$_label" "$_desc" "$_method" "$_vendor" "$_product" "$_map" "$_attached"
}

# The monitors as a list: every attached panel, then every configured panel
# that is not attached today (6).
wt_monitors() {
  local _i _ai _nf _absent _donerow _land _pick _key _row _ambiguous
  while :; do
    menu_reset
    _ambiguous=0
    _i=0
    while [ "$_i" -lt "${#WT_F[@]}" ]; do
      wt_found "$_i"
      if [ "$F_TWINS" -gt 1 ]; then
        # 6.4: drawn and unpickable. Configuration written against this
        # identity could never switch anything.
        menu_add "$F_NAME" "$F_TWINS monitors report the same id and cannot be told apart"
        menu_disable "$_i"
        _ambiguous=1
      elif _ai=$(wt_answer_index "$F_KEY"); then
        wt_rec "$_ai"
        menu_add "$F_NAME" "$R_LABEL: $(map_computers "$R_MAP" | paste -sd/ -)"
      else
        menu_add "$F_NAME" 'not managed'
      fi
      _i=$(( _i + 1 ))
    done
    _nf=${#WT_F[@]}
    _absent=()
    _i=0
    while [ "$_i" -lt "${#WT_A[@]}" ]; do
      wt_rec "$_i"
      if [ "$R_ATTACHED" -lt 0 ]; then
        _absent+=("$_i")
        menu_add "$R_NAME" "$R_LABEL: $(map_computers "$R_MAP" | paste -sd/ -), not attached"
      fi
      _i=$(( _i + 1 ))
    done
    menu_sep
    _donerow=${#MENU_ITEMS[@]}
    menu_add 'Done' ''

    # The first attached panel nobody has answered for, else Done; never a row
    # it would refuse.
    _land=$_donerow
    _i=0
    while [ "$_i" -lt "${#WT_F[@]}" ]; do
      wt_found "$_i"
      if [ "$F_TWINS" -le 1 ] && ! wt_answer_index "$F_KEY" >/dev/null; then
        _land=$_i; break
      fi
      _i=$(( _i + 1 ))
    done

    printf '\n--- monitors ---\n' >&2
    printf 'Which of these should follow the switch, and which input is each\n' >&2
    printf 'computer on?\n\n' >&2
    if [ "$_ambiguous" = 1 ]; then
      printf '  A switch cannot aim at one of them, so a greyed row cannot be set up.\n' >&2
      printf '  Unplugging one is the honest remedy today.\n\n' >&2
    fi
    select_one --default "$_land" --escapable
    _pick=$MENU_PICK
    [ "$_pick" -lt 0 ] && return 0
    [ "$_pick" -eq "$_donerow" ] && return 0

    if [ "$_pick" -lt "$_nf" ]; then
      wt_found "$_pick"
      _key=$F_KEY
      _row=$(wt_display_answers "$F_KEY" "$F_NAME" "$F_MFG" "$F_VENDOR" "$F_PRODUCT" "$_pick")
    else
      wt_rec "${_absent[$(( _pick - _nf ))]}"
      _key=$R_KEY
      _row=$(wt_display_answers "$R_KEY" "$R_NAME" '' "$R_VENDOR" "$R_PRODUCT" -1)
    fi
    [ "$_row" = "KEEP" ] && continue
    wt_answer_remove "$_key"
    [ "$_row" = "REMOVE" ] || wt_answer_add "$_row"
  done
}

# --- triggers ----------------------------------------------------------------

# A multi-select over what the watcher lists (7). A saved entry its device
# cannot be matched to today stays selected as saved.
wt_triggers() {
  local _keys _labels _details _kind _key _state _name _role _tok _where
  local _checked _i _d _new _n _rows _same _uniq _entry _what _detail _seen
  printf '\n--- triggers ---\n' >&2
  printf 'Which devices move to this computer when you flip the switch?\n' >&2
  printf 'USB rows are attached right now; Bluetooth rows are everything paired.\n\n' >&2

  _rows=$("$TK_WATCHER" --list 2>/dev/null || true)
  _keys=() _labels=() _details=()
  while IFS='|' read -r _kind _key _state _name _role _tok _where; do
    [ -n "$_key" ] || continue

    # What this row is WRITTEN as (specs/detector.md 4.1): a token held by
    # exactly one device sharing the id; the shared token plus the port where
    # the token cannot decide; else the bare id.
    _entry=$_key
    _same=$(printf '%s\n' "$_rows" | awk -F'|' -v k="$_key" '$2 == k' | wc -l | tr -d ' ')
    if [ "$_same" -gt 1 ]; then
      _uniq=$(printf '%s\n' "$_rows" |
              awk -F'|' -v k="$_key" -v t="$_tok" '$2 == k && $6 == t' | wc -l | tr -d ' ')
      if [ -n "$_tok" ] && [ "$_uniq" = 1 ]; then
        _entry="$_key@$_tok"
      elif [ -n "$_tok" ] && [ -n "$_where" ]; then
        _entry="$_key@$_tok@$_where"
      fi
    fi

    _keys+=("$_entry")
    # 7.1: the row says WHAT the device is; the id stays beside it.
    _what=$_name
    [ -n "$_role" ] && _what="$_name ($_role)"
    _labels+=("$(tk_pad "$_what" 34)")
    _detail=$(printf '%-22s %s' "$_key" "$_state")
    [ "$_same" -gt 1 ] && _detail="$_detail  -- 1 of $_same sharing this id"
    _details+=("$_detail")
  done <<EOF
$_rows
EOF

  # A saved entry nothing above matches is offered as saved, still selected.
  for _d in ${WT_DEVICES[@]+"${WT_DEVICES[@]}"}; do
    _seen=0
    for _entry in ${_keys[@]+"${_keys[@]}"}; do [ "$_entry" = "$_d" ] && _seen=1; done
    [ "$_seen" = 1 ] && continue
    _keys+=("$_d")
    _labels+=("$(tk_pad "$_d" 34)")
    _details+=('not attached now  -- kept as saved')
  done

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
  # Saved entries keep their order; new ones follow.
  _new=()
  for _d in ${WT_DEVICES[@]+"${WT_DEVICES[@]}"}; do
    for _n in $MENU_PICKED; do [ "${_keys[$_n]}" = "$_d" ] && _new+=("$_d"); done
  done
  for _n in $MENU_PICKED; do
    _seen=0
    for _d in ${_new[@]+"${_new[@]}"}; do [ "$_d" = "${_keys[$_n]}" ] && _seen=1; done
    [ "$_seen" = 1 ] || _new+=("${_keys[$_n]}")
  done
  WT_DEVICES=("${_new[@]+${_new[@]}}")
  WT_RAN_TRIGGERS=''
}

# --- autostart ---------------------------------------------------------------

# Can this account obtain root? Membership of admin is what sudoers grants.
wt_is_admin() { id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; }

# Three rows, from boot highlighted (8). The boot tier runs as the user,
# unelevated; the password installs it.
wt_tier() {
  local _now _default
  printf '\n--- should it start on its own? ---\n' >&2
  printf '  It can start as soon as the computer starts, or after you log in for\n' >&2
  printf '  the first time. Starting before you log in needs your password once,\n' >&2
  printf '  now, to install it. Nothing runs as an administrator afterwards.\n\n' >&2
  printf '  Answering no still installs and starts it now; it just will not come\n' >&2
  printf '  back after a restart until you run:  trigger-kvm restart\n\n' >&2

  menu_reset
  if wt_is_admin; then
    menu_add 'From boot' 'needs your password once, to install'
  else
    menu_add 'From boot' 'needs an administrator account'
    menu_disable 0
  fi
  menu_add 'From login' 'no password needed'
  menu_add 'No -- I will start it myself' ''

  _now=-1
  case $WT_TIER in boot) _now=0 ;; login) _now=1 ;; no) _now=2 ;; esac
  _default=0
  [ "$_now" -ge 0 ] && _default=$_now
  menu_is_disabled "$_default" && _default=1

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

# Append one line to the login shell's rc file: the bin directory only.
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

# --- the menu IS the flow ----------------------------------------------------

# A monitor-input check belongs to the answers it was given (10.8). Any edit
# since retires it, whatever it said.
wt_forget_check() {
  WT_RAN_DISPLAYS=''; WT_DISPLAYS_OK=''; WT_PASS_SIG=''
  WT_CHECKED_SIG=$(wt_answers_signature)
}

# The walkthrough (4). The current config pre-fills everything; --fresh
# pre-fills nothing but still carries hand-written keys through on Save.
cmd_configure() {
  local _fresh _isfirst _i _c _d _pathrow _claims _disprow _trigrow _saverow
  local _land _pick _missing
  _fresh=0
  [ "${1:-}" = "--fresh" ] && _fresh=1

  _isfirst=1
  [ -f "$CONFIG" ] && _isfirst=0

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
  if [ "${#WT_F[@]}" -eq 0 ]; then
    tk_log 'no external displays found -- nothing to configure.'
    exit 2
  fi

  printf '\n--- monitors found (%s) ---\n' "${#WT_F[@]}" >&2
  _i=0
  while [ "$_i" -lt "${#WT_F[@]}" ]; do
    wt_found "$_i"
    printf '  %-24s EDID %s\n' "$F_NAME" "$F_KEY" >&2
    _i=$(( _i + 1 ))
  done

  if [ "$_fresh" = "1" ]; then
    WT_THIS=''; WT_COMPUTERS=(); WT_DEVICES=(); WT_TIER=''; WT_A=()
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
  wt_forget_check

  while :; do
    [ "$(wt_answers_signature)" = "$WT_CHECKED_SIG" ] || wt_forget_check

    menu_reset

    # One punctuation rule down the value column: ", " separates items, ": "
    # a label from its value, "/" things sharing a label. The wrapper breaks
    # at ", ".
    if [ "${#WT_COMPUTERS[@]}" -eq 0 ]; then _d='not set'; else
      _d=''
      for _c in "${WT_COMPUTERS[@]}"; do
        if [ "$_c" = "$WT_THIS" ]; then _d="$_d, $_c (this)"; else _d="$_d, $_c"; fi
      done
      _d=${_d#, }
    fi
    menu_add 'Computers' "$_d"

    if [ "${#WT_A[@]}" -eq 0 ]; then _d='not set'; else
      _d=''
      _i=0
      while [ "$_i" -lt "${#WT_A[@]}" ]; do
        wt_rec "$_i"
        _d="$_d, $R_LABEL: $(map_computers "$R_MAP" | paste -sd/ -)"
        _i=$(( _i + 1 ))
      done
      _d=${_d#, }
    fi
    menu_add 'Monitors' "$_d"

    if [ "${#WT_DEVICES[@]}" -eq 0 ]; then _d='not set'
    else _d=$(printf '%s' "${WT_DEVICES[*]}" | sed 's/ /, /g'); fi
    menu_add 'Triggers' "$_d"

    # Nothing is preset (4.3): the suggestion is the highlighted row inside
    # the submenu.
    case $WT_TIER in
      boot)  _d='from boot' ;;
      login) _d='from login' ;;
      no)    _d='no' ;;
      *)     _d='not set' ;;
    esac
    menu_add 'Autostart?' "$_d"

    # Always drawn; disabled when there is nothing to decide (9).
    _pathrow=${#MENU_ITEMS[@]}
    if [ "$WT_ONPATH" = "1" ]; then _d='already on PATH'
    elif [ -z "$WT_WANTPATH" ]; then _d='not set'
    else _d=$WT_WANTPATH; fi
    menu_add 'Add to PATH?' "$_d"
    [ "$WT_ONPATH" = "1" ] && menu_disable "$_pathrow"

    menu_sep

    # Singular when there is exactly one thing to check.
    _claims=0
    _i=0
    while [ "$_i" -lt "${#WT_A[@]}" ]; do
      wt_rec "$_i"
      for _c in $(map_computers "$R_MAP"); do
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

    # Where the cursor lands is the recommendation (4.2): the next thing not
    # done; a failed check sends it to the setting that failed.
    if   [ "${#WT_COMPUTERS[@]}" -eq 0 ]; then _land=0
    elif [ "${#WT_A[@]}"         -eq 0 ]; then _land=1
    elif [ "${#WT_DEVICES[@]}"   -eq 0 ]; then _land=2
    elif [ -z "$WT_TIER" ];             then _land=3
    elif [ "$WT_ONPATH" = "0" ] && [ -z "$WT_WANTPATH" ]; then _land=$_pathrow
    elif [ -z "$WT_RAN_DISPLAYS" ];     then _land=$_disprow
    elif [ "$WT_DISPLAYS_OK" = "0" ];   then _land=1
    elif [ -z "$WT_RAN_TRIGGERS" ];     then _land=$_trigrow
    elif [ "$WT_TRIGGERS_OK" = "0" ];   then _land=2
    else _land=$_saverow; fi

    printf '\n' >&2
    if [ "${#WT_A[@]}" -gt 0 ] && [ "${#WT_DEVICES[@]}" -gt 0 ]; then
      printf -- '--- review configuration ---\n\n' >&2
    else
      printf -- '--- configuration ---\n\n' >&2
    fi

    # Esc moves the cursor to Cancel; it does not take it (3.3).
    select_one --default "$_land" --escape-to $(( _saverow + 1 ))
    _pick=$MENU_PICK

    if [ "$_pick" -eq $(( _saverow + 1 )) ]; then
      tk_log 'cancelled; nothing was changed.'
      exit 1
    fi

    if [ "$_pick" -eq "$_saverow" ]; then
      _missing=''
      [ "${#WT_COMPUTERS[@]}" -eq 0 ] && _missing="$_missing
Computers"
      [ "${#WT_A[@]}"         -eq 0 ] && _missing="$_missing
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
