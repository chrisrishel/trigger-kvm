# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# The verbs that look at, or move, the monitors: list, discover, pull, to, set.

# --- list --------------------------------------------------------------------

# The attached displays as a table, given the enumeration, saying which
# configured label each is. One row per attached panel: two panels of one model
# are two rows, each saying the id names more than one (specs/configure.md 6.4).
cmd_list_table() {
  local _found _known _l _v _p _vn _pn _mfg _conn _ser _uuid _name _key _as _n
  _found=$1

  _known=""
  for _l in $(config_display_labels); do
    _v=$(config_get "display.$_l.vendor"); _p=$(config_get "display.$_l.product")
    if _vn=$(config_to_word "$_v") && _pn=$(config_to_word "$_p"); then
      _known="$_known$(printf '%04X:%04X\t%s\n' "$_vn" "$_pn" "$_l")
"
    fi
  done

  printf '\n'
  printf '  %-8s %-9s %-11s %-22s %s\n' vendor product connector 'name (from the panel)' 'configured as'
  printf '  %-8s %-9s %-11s %-22s %s\n' ------ ------- --------- --------------------- -------------
  printf '%s\n' "$_found" | while IFS='|' read -r _v _p _mfg _conn _ser _uuid _name; do
    _key="$_v:$_p"
    _as=$(printf '%s' "$_known" | awk -F'\t' -v k="$_key" '$1 == k { print $2; exit }')
    [ -n "$_as" ] || _as='-- not in config --'
    [ -n "$_name" ] || _name="($_mfg, unnamed)"
    _n=$(display_identity_count "$_found" "$_key")
    [ "$_n" -gt 1 ] && _as="$_as  <- $_n monitors report the same id and cannot be told apart"
    printf '  0x%s   0x%s    %-11s %-22s %s\n' "$_v" "$_p" "${_conn:--}" "$_name" "$_as"
  done
}

# What is attached, in the exact form the config wants. Moves nothing.
cmd_list() {
  local _found _ex
  _found=$(display_enumerate) || exit 2
  if [ -z "$_found" ]; then
    tk_log 'no external displays found'
    exit 2
  fi

  if [ "$RAW" = "1" ]; then
    printf '%s\n' "$_found"
    exit 0
  fi

  cmd_list_table "$_found"

  printf '\n'
  echo 'To add one, put this in the config and name the input each computer is on:'
  printf '\n'
  _ex=$(printf '%s\n' "$_found" | head -1)
  printf '    display.<label>.vendor  = 0x%s\n' "$(display_field "$_ex" 1)"
  printf '    display.<label>.product = 0x%s\n' "$(display_field "$_ex" 2)"
  echo  '    display.<label>.name    = <a name for logs>'
  echo  '    display.<label>.method  = standard        # or lg-alt, for an LG whose 0x60 is stubbed'
  echo  '    display.<label>.input.0x11 = pc           # name each input after what is plugged in'
  # shellcheck disable=SC2016  # the backticks are prose, quoting a command name
  echo  '    display.<label>.input.0x0f = mac          # `pull` uses computer.this; `to mac` uses this'
  printf '\n'
  echo 'NOTE: some panels report a DIFFERENT product id per input -- the LG 45GX950A does.'
  echo 'Use the value shown HERE, measured on this computer. Never copy one from another host.'
  exit 0
}

# --- discover ----------------------------------------------------------------

# What is attached, displays and trigger candidates, in the form the config
# wants. Devices come from `event-watch --list`: that program owns "is that
# device here?", and a second enumeration here could disagree with the one
# that fires.
cmd_discover() {
  local _found _cur _rows _kind _key _state _name _role _tok _where _mark _n
  printf '\n=== displays on this computer ===\n'
  if _found=$(display_enumerate) && [ -n "$_found" ]; then
    cmd_list_table "$_found"
  else
    printf '  (none found)\n'
  fi

  printf '\n=== devices that could be a trigger ===\n\n'
  echo 'The trigger is whatever MOVES when you flip the switch. Pick the ones that'
  echo 'travel; USB rows are what is attached right now, Bluetooth rows what is paired.'
  printf '\n'

  _cur=$(config_trigger_devices | tr '\n' ' ')
  _rows=$("$TK_WATCHER" --list 2>/dev/null || true)
  if [ -z "$_rows" ]; then
    echo '  (none found)'
  else
    # specs/configure.md 7.1: the row says WHAT the device is, with the id it
    # is matched on beside it.
    printf '  %-26s %-16s %-22s %s\n' 'device' 'role' 'id' 'state'
    printf '  %-26s %-16s %-22s %s\n' ------ ---- -- -----
    printf '%s\n' "$_rows" | while IFS='|' read -r _kind _key _state _name _role _tok _where; do
      _mark=''
      case " $_cur " in *" $_key "*) _mark='  <- currently a trigger' ;; esac
      _n=$(printf '%s\n' "$_rows" | awk -F'|' -v k="$_key" '$2 == k' | wc -l | tr -d ' ')
      [ "$_n" -gt 1 ] && _mark="$_mark  ($_n devices share this id)"
      printf '  %s %s %-22s %s%s\n' \
             "$(tk_pad "$_name" 26)" "$(tk_pad "${_role:--}" 16)" \
             "$_key" "$_state" "$_mark"
    done
  fi

  printf '\n'
  echo 'Bluetooth entries are every PAIRED device. One that is not connected right now'
  echo 'is still a fine trigger -- better, even: a trigger fires on ARRIVAL, and that is'
  echo 'what connecting is. USB rows are only devices attached at this moment, because'
  echo 'there is no way to ask about a USB device that is somewhere else.'
  printf '\n'
  echo 'TRAP: match the FULL vendor+product pair. A keyboard and mouse often share a'
  echo 'vendor id with a webcam and are always present, so a vendor-only match fires'
  echo 'constantly.'
  printf 'config: %s\n' "$CONFIG"
  exit 0
}

# --- pull / to / set ---------------------------------------------------------

# Point every configured display (or --only one) at a computer, or with `set`
# at a raw value. pull and to are one lookup, one name apart: pull looks up
# computer.this in the map, to looks up the name given.
#
# Every value is resolved BEFORE anything is sent, and one that cannot be
# refuses the whole operation: a half-applied arrangement leaves the desk in a
# state nobody configured.
cmd_switch() {
  local _labellist _l _plan _who _value _known _rc _v
  _labellist=$(config_display_labels)
  if [ -z "$_labellist" ]; then
    tk_log "no displays configured. Expected a config at $CONFIG; run: trigger-kvm configure"
    exit 2
  fi

  if [ "$ONLY" != "all" ]; then
    if ! printf '%s\n' "$_labellist" | grep -qx "$ONLY"; then
      tk_log "no configured display labelled '$ONLY'. Known: $(printf '%s' "$_labellist" | tr '\n' ' ')"
      exit 2
    fi
    _labellist=$ONLY
  fi

  _plan=""
  for _l in $_labellist; do
    if [ "$VERB" = "set" ]; then
      if [ "$ONLY" = "all" ]; then
        tk_log 'set requires --only naming exactly one display'
        exit 2
      fi
      if ! _value=$(config_to_byte "$VALUE"); then
        tk_log "REFUSING: --value '$VALUE' is not a byte (use 0x11 or 17). Nothing was sent."
        exit 2
      fi
    else
      if [ "$VERB" = "pull" ]; then _who=$(config_this_computer); else _who=$(tk_lower "$WHO"); fi
      if [ -z "$_who" ]; then
        if [ "$VERB" = "pull" ]; then
          tk_log "REFUSING: computer.this is missing from $CONFIG. Run: trigger-kvm configure"
        else
          tk_log 'usage: trigger-kvm to <computer>'
        fi
        exit 2
      fi

      _value=$(config_input_for "$_l" "$_who")
      if [ -z "$_value" ]; then
        _known=$(config_input_map "$_l" | cut -f1 | sort | tr '\n' ' ')
        if [ -n "$_known" ]; then _known="it knows: $_known"; else _known='it names no computers at all'; fi
        tk_log "REFUSING: '$_l' has no input named '$_who' ($_known). Nothing was sent."
        exit 2
      fi
      if [ "$_value" = "AMBIGUOUS" ]; then
        tk_log "REFUSING: '$_l' names '$_who' on more than one input. Fix $CONFIG. Nothing was sent."
        exit 2
      fi
    fi
    _plan="$_plan$_l$(printf '\t')$_value
"
  done

  # A here-document, not a pipe: a `while` on the right of a pipe runs in a
  # subshell and _rc would be lost with it.
  _rc=0
  while IFS=$'\t' read -r _l _v; do
    [ -n "$_l" ] || continue
    display_switch "$_l" "$_v" "$DRY" || _rc=1
  done <<EOF
$_plan
EOF

  # Zero means the writes were SENT. Whether the monitors switched is confirmed
  # by looking at them.
  exit $_rc
}
