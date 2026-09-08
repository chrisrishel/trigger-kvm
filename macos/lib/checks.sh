# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# The two checks: the only part of this program that deliberately moves a
# monitor while someone is watching (specs/configure.md 10 and 11).
#
# What is under test is the claim that input V of panel P is computer C. A
# switch is confirmed by a person looking at it, never by a return code and
# never by reading a value back.

# How long a panel is held away before it is brought back, and how long the
# return is given to settle. Turned down by the suite.
TK_HOLD=${TK_HOLD:-8}
TK_SETTLE_BACK=${TK_SETTLE_BACK:-2}
TK_WALK_HOLD=${TK_WALK_HOLD:-6}

# The one place a check moves a monitor, so a test harness has one thing to
# stand in for.
wt_send_input() {
  "$TK_SELF" set --only "$1" --value "$2" --config "$3" >/dev/null 2>&1 || true
}

# What the monitor's own menu calls a value, from the channel's own table:
# recovery instructions say "choose HDMI 1", never "choose 0x11" or "choose pc".
wt_input_name() {
  local _i
  wt_input_table "$1" ''
  _i=0
  while [ "$_i" -lt "${#IT_VALUES[@]}" ]; do
    if [ "$(tk_lower "${IT_VALUES[$_i]}")" = "$(tk_lower "$2")" ]; then
      printf '%s\n' "${IT_NAMES[$_i]}"; return 0
    fi
    _i=$(( _i + 1 ))
  done
  printf '\n'
}

# --- the monitor inputs ------------------------------------------------------

# The check runs against a throwaway config: the switcher takes its map from a
# file, and nothing is written until Save.
WT_RAN_DISPLAYS=''
WT_DISPLAYS_OK=''
WT_PASS_SIG=''
WT_CHECKED_SIG=''
wt_check_displays() {
  local _tmp _scope _i _attached _scoped _others _targets _c _bad _skipped _target
  local _panels _np _nscoped _rounds _head _last _old _round _f
  _tmp=$(mktemp -t trigger-kvm-check)
  # shellcheck disable=SC2064
  trap "rm -f '$_tmp'" RETURN
  wt_write_config "$_tmp"

  # Only attached panels can be checked (10.1).
  _attached=$(wt_attached_managed | tr '\n' ' ')
  if [ -z "$_attached" ]; then
    printf '\n  None of the managed monitors is attached right now.\n' >&2
    WT_RAN_DISPLAYS='not checked'; WT_DISPLAYS_OK=''; return 0
  fi

  _scope=''
  if [ "$(printf '%s' "$_attached" | wc -w | tr -d ' ')" -gt 1 ]; then
    printf '\n  Which monitor do you want to check?\n' >&2
    menu_reset
    menu_add 'All of them' ''
    for _i in $_attached; do wt_rec "$_i"; menu_add "$R_NAME" ''; done
    select_one --default 0 --escapable
    if [ "$MENU_PICK" -lt 0 ]; then
      # Neither a pass nor a failure (4.2).
      WT_RAN_DISPLAYS='not checked'; WT_DISPLAYS_OK=''; return 0
    fi
    [ "$MENU_PICK" -gt 0 ] && _scope=$(printf '%s' "$_attached" | tr ' ' '\n' | sed -n "${MENU_PICK}p")
  fi
  if [ -n "$_scope" ]; then _scoped=$_scope; else _scoped=$_attached; fi

  # Every other computer any scoped panel claims.
  _others=''
  for _i in $_scoped; do
    wt_rec "$_i"
    for _c in $(map_computers "$R_MAP"); do
      [ "$_c" = "$WT_THIS" ] && continue
      case " $_others " in *" $_c "*) ;; *) _others="$_others $_c" ;; esac
    done
  done

  _bad=''
  _skipped=0
  # With no other computer there is no claim to check beyond "the transport
  # reaches each panel": one pass, sending each to another of its inputs (10.2).
  _targets=$_others
  [ -n "$_targets" ] || _targets='-'
  for _target in $_targets; do
    [ "$_target" = '-' ] && _target=''
    _panels=''
    for _i in $_scoped; do
      wt_rec "$_i"
      [ -n "$(map_get "$R_MAP" "$WT_THIS")" ] || continue
      if [ -z "$_target" ] || [ -n "$(map_get "$R_MAP" "$_target")" ]; then _panels="$_panels $_i"; fi
    done
    [ -n "$_panels" ] || continue

    # HARD RULE 4: one panel always stays on this computer. When every panel
    # being checked would move, that is two rounds.
    _np=$(printf '%s' "$_panels" | wc -w | tr -d ' ')
    _nscoped=$(printf '%s' "$_scoped" | wc -w | tr -d ' ')
    if [ "$_np" -eq "$_nscoped" ] && [ "$_np" -gt 1 ]; then
      _head='' _last=''
      for _i in $_panels; do _head="$_head $_last"; _last=$_i; done
      _rounds="$(printf '%s' "$_head" | sed 's/^ *//')|$_last"
    else
      _rounds="$(printf '%s' "$_panels" | sed 's/^ *//')"
    fi

    _old=$IFS; IFS='|'
    for _round in $_rounds; do
      IFS=$_old
      [ -n "$_round" ] || { IFS='|'; continue; }
      wt_check_round "$_round" "$_target" "$_tmp"
      # Newline-separated: a panel is called "LG ULTRAGEAR+".
      while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        case "
$_bad
" in *"
$_f
"*) ;; *) _bad="$_bad
$_f" ;; esac
      done <<INNER
$WT_ROUND_BAD
INNER
      [ "$WT_ROUND_SKIPPED" = "1" ] && _skipped=1
      IFS='|'
    done
    IFS=$_old
  done

  # A pass is bound to what was checked (10.8); an edit retires it.
  WT_CHECKED_SIG=$(wt_answers_signature)
  WT_PASS_SIG=''
  if [ "$_skipped" = "1" ]; then
    WT_RAN_DISPLAYS='not checked'; WT_DISPLAYS_OK=''; return 0
  fi
  _bad=$(printf '%s' "$_bad" | grep -v '^$' || true)
  if [ -n "$_bad" ]; then
    WT_RAN_DISPLAYS="trouble with $(printf '%s' "$_bad" | tk_join_names)"
    WT_DISPLAYS_OK=0
  else
    WT_RAN_DISPLAYS='all responded'
    WT_DISPLAYS_OK=1
    # shellcheck disable=SC2086  # a list of indices, meant to split
    WT_PASS_SIG=$(wt_pass_signature $_scoped)
  fi
  return 0
}

# May the trigger check pull for real? Only with a current pass covering every
# managed, attached panel (10.8, 11).
wt_pull_allowed() {
  [ "$WT_DISPLAYS_OK" = "1" ] || return 1
  # shellcheck disable=SC2046  # a list of indices, meant to split
  [ "$WT_PASS_SIG" = "$(wt_pass_signature $(wt_attached_managed))" ]
}

# Where a panel goes for a check: the target computer's input, or with no
# target the first value on its channel that is not this computer's. Sets
# WT_CAND and WT_CAND_NAME; false when the panel has nowhere to go.
WT_CAND=''
WT_CAND_NAME=''
wt_candidate() {
  local _here _j
  wt_rec "$1"
  WT_CAND='' WT_CAND_NAME=''
  if [ -n "$2" ]; then
    WT_CAND=$(map_get "$R_MAP" "$2"); WT_CAND_NAME=$2
    [ -n "$WT_CAND" ]
    return
  fi
  _here=$(map_get "$R_MAP" "$WT_THIS")
  wt_input_table "$R_METHOD" "$R_MAP"
  _j=0
  while [ "$_j" -lt "${#IT_VALUES[@]}" ]; do
    if [ "$(tk_lower "${IT_VALUES[$_j]}")" != "$(tk_lower "$_here")" ]; then
      WT_CAND=${IT_VALUES[$_j]}; WT_CAND_NAME=${IT_NAMES[$_j]}; return 0
    fi
    _j=$(( _j + 1 ))
  done
  return 1
}

# THE SWING: send a group of panels away, hold, bring them all back, settle.
# Every path that moves a panel goes through here, and through its preamble
# (10.2, 10.7). WT_ROUND_SKIPPED=1 when the person declined.
WT_ROUND_SKIPPED=0
wt_swing() {
  local _round _target _cfg _hold _names _i _namelist _stays _staylist _n _verb
  local _solo _back _bname _what
  _round=$1 _target=$2 _cfg=$3 _hold=${4:-$TK_HOLD}
  WT_ROUND_SKIPPED=0

  _names=''
  for _i in $_round; do wt_rec "$_i"; _names="$_names
$R_NAME"; done
  _namelist=$(printf '%s' "${_names#
}" | tk_join_names)

  # What stays is every managed, attached panel not in this round.
  _stays=''
  for _i in $(wt_attached_managed); do
    case " $_round " in
      *" $_i "*) ;;
      *) wt_rec "$_i"; _stays="$_stays
$R_NAME" ;;
    esac
  done

  if [ -n "$_target" ]; then _what=$_target; else _what='another input'; fi
  printf '\n  Sending %s to %s for %ss, then back automatically.\n' "$_namelist" "$_what" "$_hold" >&2
  if [ -n "$_target" ]; then
    printf '  If %s is asleep or off you will see No Signal, which still proves the\n' "$_target" >&2
    printf '  switch worked.\n' >&2
  else
    printf '  It only has to CHANGE: if nothing is plugged into that input it will say\n' >&2
    printf '  No Signal, and that still proves the switch worked.\n' >&2
  fi

  if [ -n "$_stays" ]; then
    _staylist=$(printf '%s' "${_stays#
}" | tk_join_names)
    _n=$(printf '%s' "${_stays#
}" | grep -c . || true)
    if [ "$_n" -eq 1 ]; then _verb=stays; else _verb=stay; fi
    printf '\n  %s %s here, so you can read this.\n' "$_staylist" "$_verb" >&2
    # Said every round: this cannot see where the window is.
    printf '  If this window is on %s, drag it to %s first: if the switch back\n' \
           "$_namelist" "$(printf '%s' "${_stays#
}" | head -1)" >&2
    printf '  fails, the window goes dark with it and there is no way to answer.\n' >&2
    menu_read_line '  Enter when ready' '' >/dev/null || menu_eof
  else
    # The only monitor: say how to get back while there is a screen to read it on.
    _solo=$(printf '%s' "$_round" | awk '{print $1}')
    wt_rec "$_solo"
    _back=$(map_get "$R_MAP" "$WT_THIS")
    _bname=$(wt_input_name "$R_METHOD" "$_back")
    printf '\n  READ THIS FIRST -- this is your only monitor.\n' >&2
    printf '  You will not be able to read anything while it is away.\n\n' >&2
    printf '  IF IT DOES NOT COME BACK there is nothing this tool can do for you --\n' >&2
    printf '  it cannot draw on a screen that is showing another computer. The way\n' >&2
    printf '  back is the monitor itself: press its input (or source) button and\n' >&2
    if [ -n "$_bname" ]; then
      printf '  choose %s, value %s. No software can take that button away from you.\n' "$_bname" "$_back" >&2
    else
      printf '  choose value %s. No software can take that button away from you.\n' "$_back" >&2
    fi
    printf '\n' >&2
    if ! read_yesno '  Ready?' y; then
      printf '  Skipped. Nothing was sent.\n' >&2
      WT_ROUND_SKIPPED=1
      return 0
    fi
  fi

  for _i in $_round; do
    wt_candidate "$_i" "$_target" || continue
    wt_send_input "$R_LABEL" "$WT_CAND" "$_cfg"
  done
  sleep "$_hold"
  for _i in $_round; do
    wt_rec "$_i"
    wt_send_input "$R_LABEL" "$(map_get "$R_MAP" "$WT_THIS")" "$_cfg"
  done
  sleep "$TK_SETTLE_BACK"
  return 0
}

# One round: swing a group of panels together and ask ONCE; narrow only on a
# no (10.3). Batched across panels, never across computers.
WT_ROUND_BAD=''
wt_check_round() {
  local _round _target _cfg _names _i _namelist _count _q _wrong _idx _p
  _round=$1 _target=$2 _cfg=$3
  WT_ROUND_BAD=''

  wt_swing "$_round" "$_target" "$_cfg"
  [ "$WT_ROUND_SKIPPED" = "1" ] && return 0

  _names=''
  for _i in $_round; do wt_rec "$_i"; _names="$_names
$R_NAME"; done
  _namelist=$(printf '%s' "${_names#
}" | tk_join_names)
  _count=$(printf '%s' "$_round" | wc -w | tr -d ' ')
  printf '\n' >&2
  if [ -z "$_target" ]; then
    if [ "$_count" -eq 1 ]; then _q="  Did $_namelist change, then come back?"
    else _q='  Did all of them change, then come back?'; fi
  elif [ "$_count" -eq 1 ]; then _q="  Did $_namelist show $_target, then come back?"
  else _q="  Did all of them show $_target, then come back?"; fi
  if read_yesno "$_q" y; then return 0; fi

  _wrong=$_round
  if [ "$_count" -gt 1 ]; then
    printf '\n  Which ones did not?\n' >&2
    menu_reset
    for _i in $_round; do wt_rec "$_i"; menu_add "$R_NAME" "$R_LABEL"; done
    select_many
    _wrong=''
    _idx=0
    for _i in $_round; do
      for _p in $MENU_PICKED; do [ "$_p" = "$_idx" ] && _wrong="$_wrong $_i"; done
      _idx=$(( _idx + 1 ))
    done
  fi

  for _i in $_wrong; do
    if ! wt_check_one "$_i" "$_target" "$_cfg"; then
      wt_rec "$_i"
      WT_ROUND_BAD="$WT_ROUND_BAD
$R_NAME"
    fi
  done
  WT_ROUND_BAD=$(printf '%s' "$WT_ROUND_BAD" | grep -v '^$' || true)
  return 0
}

# Swing one panel and ask what happened, in the order it happened (10.4).
# WT_OUTCOME: 0 correct, 1 changed to the wrong thing, 2 went and did not come
# back, 3 nothing happened, 4 declined.
WT_OUTCOME=0
wt_probe_one() {
  local _i _target _cfg
  _i=$1 _target=$2 _cfg=$3
  wt_candidate "$_i" "$_target" || { WT_OUTCOME=0; return 0; }
  wt_swing "$_i" "$_target" "$_cfg"
  [ "$WT_ROUND_SKIPPED" = "1" ] && { WT_OUTCOME=4; return 0; }
  wt_rec "$_i"

  printf '\n  Did the %s change to %s, and back to %s?\n' "$R_NAME" "$WT_CAND_NAME" "$WT_THIS" >&2
  menu_reset
  menu_add "Yes, and it changed back to $WT_THIS"     'everything works'
  menu_add "Yes, but it did not change back to $WT_THIS" "the input for $WT_THIS is wrong"
  menu_add 'No' ''
  select_one --default 0
  case $MENU_PICK in
    0) WT_OUTCOME=0; return 0 ;;
    1) WT_OUTCOME=2; return 0 ;;
  esac

  # Testing a bare input value, any change proves the transport; only a target
  # computer leaves a second question.
  if [ -z "$_target" ]; then WT_OUTCOME=3; return 0; fi

  printf '\n  Did the %s change at all?\n' "$R_NAME" >&2
  menu_reset
  menu_add "Yes, but it was not $_target" "that input is not $_target"
  menu_add 'No, nothing happened'         'this panel does not answer on this channel'
  select_one --default 1
  if [ "$MENU_PICK" = "0" ]; then WT_OUTCOME=1; else WT_OUTCOME=3; fi
  return 0
}

# One panel, one computer: swing it, act on what the person saw, retry ONCE
# per fix. Returns 0 when it passed.
wt_check_one() {
  local _i _target _cfg _attempt _here _vendor _di _what _alt _to _offer _j _keep _c _allownone
  _i=$1 _target=$2 _cfg=$3 _attempt=${4:-1}

  # Written before every attempt: a fix changes the file the switcher reads.
  wt_write_config "$_cfg"
  wt_probe_one "$_i" "$_target" "$_cfg"
  wt_rec "$_i"
  _here=$(map_get "$R_MAP" "$WT_THIS")

  [ "$WT_OUTCOME" = "0" ] && return 0
  [ "$WT_OUTCOME" = "4" ] && return 1
  [ "$_attempt" -ge 2 ] && return 1

  # 1: the panel obeys; that input is just not the computer we thought.
  if [ "$WT_OUTCOME" = "1" ] && [ -n "$_target" ]; then
    printf '\n  So that input is not %s. Which one is?\n' "$_target" >&2
    wt_read_input "$R_METHOD" "$R_MAP" \
      "On the $R_NAME, which input is '$_target' on?" '' \
      "$(map_get "$R_MAP" "$_target")" "$_target" 1
    if [ "$WT_INPUT_NONE" = "1" ]; then
      wt_answer_set "$_i" map "$(map_del "$R_MAP" "$_target")"
      return 0
    fi
    wt_answer_set "$_i" map "$(map_set "$R_MAP" "$_target" "$WT_INPUT_VALUE")"
    wt_check_one "$_i" "$_target" "$_cfg" $(( _attempt + 1 ))
    return $?
  fi

  # 2: the channel is right; the value for THIS computer is not.
  if [ "$WT_OUTCOME" = "2" ]; then
    printf '\n  So %s responds -- the channel is right. The input for this\n' "$R_NAME" >&2
    printf "  computer is not. Use that monitor's own buttons to bring it back,\\n" >&2
    printf '  then tell me which input that is.\n\n' >&2
    if read_yesno '  Do you know which input it is?' y; then
      wt_read_input "$R_METHOD" "$R_MAP" \
        "On the $R_NAME, which input is '$WT_THIS' on?" '' "$_here" "$WT_THIS" 0
      wt_answer_set "$_i" map "$(map_set "$R_MAP" "$WT_THIS" "$WT_INPUT_VALUE")"
    else
      if ! wt_blind_walk "$_i" "$_cfg"; then return 1; fi
      wt_answer_set "$_i" map "$(map_set "$R_MAP" "$WT_THIS" "$WT_WALK_FOUND")"
    fi
    wt_check_one "$_i" "$_target" "$_cfg" $(( _attempt + 1 ))
    return $?
  fi

  # 3: nothing at all. The channel is wrong, and a method change is OFFERED
  # from documented values, in either direction (10.5).
  _vendor=$(printf '%s' "$R_KEY" | cut -d: -f1)
  if _di=$(wt_dialect_for "$_vendor"); then
    _what=${DIALECT_WHAT[$_di]}
    _alt=${DIALECT_METHOD[$_di]}

    if [ "$R_METHOD" != "$_alt" ]; then
      _to=$_alt
      printf '\n  %s did not answer the standard channel. It is %s, and some %s\n' \
             "$R_NAME" "$_what" "$_what" >&2
      printf '  panels put input switching on a manufacturer channel instead. These\n' >&2
      printf '  values are documented for %s, and are the only ones that will be\n' "$_what" >&2
      printf '  sent -- nothing is guessed at on a manufacturer channel:\n\n' >&2
      _offer="Yes, try the $_what channel"
    else
      _to=standard
      printf '\n  %s is on %s'"'"'s own method and did not answer it. The standard method\n' \
             "$R_NAME" "$_what" >&2
      printf '  is the other thing to try. These are its documented values:\n\n' >&2
      _offer='Yes, try the standard method'
    fi

    wt_input_table "$_to" ''
    _j=0
    while [ "$_j" -lt "${#IT_NAMES[@]}" ]; do
      printf '    %-14s %s\n' "${IT_NAMES[$_j]}" "${IT_VALUES[$_j]}" >&2
      _j=$(( _j + 1 ))
    done
    printf '\n' >&2

    menu_reset
    menu_add "$_offer" 'and say which input each computer is on'
    menu_add 'No, leave this monitor out' 'everything else stays configured'
    select_one --default 0 --escapable
    if [ "$MENU_PICK" = "0" ]; then
      # The old map was for a channel that does not work; it starts again.
      _keep=$(map_computers "$R_MAP")
      wt_answer_set "$_i" method "$_to"
      wt_answer_set "$_i" map ''
      for _c in $_keep; do
        wt_rec "$_i"
        _allownone=1
        [ "$_c" = "$WT_THIS" ] && _allownone=0
        wt_read_input "$R_METHOD" "$R_MAP" \
          "On the $R_NAME, which input is '$_c' on?" '' '' "$_c" "$_allownone"
        [ "$WT_INPUT_NONE" = "1" ] || wt_answer_set "$_i" map "$(map_set "$R_MAP" "$_c" "$WT_INPUT_VALUE")"
      done
      wt_check_one "$_i" "$_target" "$_cfg" $(( _attempt + 1 ))
      return $?
    fi
    return 1
  fi

  printf '\n  %s did not answer the standard channel, and no manufacturer values\n' "$R_NAME" >&2
  printf '  are known here for %s. That panel may not support DDC/CI input\n' "$_vendor" >&2
  printf '  switching at all, or may use a channel nobody has documented.\n\n' >&2
  printf '  Everything else is still configured; this monitor just will not follow\n' >&2
  printf '  the switch. Leave it out with Monitors -> "Manage this monitor? no".\n' >&2
  return 1
}

# Last resort: each standard input value in turn until the panel comes back
# (10.6). Standard DDC/CI only, offered with its cost, refused for the only
# monitor.
WT_WALK_FOUND=''
wt_blind_walk() {
  local _i _cfg _j
  _i=$1 _cfg=$2
  WT_WALK_FOUND=''
  wt_rec "$_i"

  printf '\n--- try the standard values one at a time ---\n' >&2
  if [ "$R_METHOD" != "standard" ]; then
    printf '  Only offered on the standard channel. A manufacturer channel takes\n' >&2
    printf '  values from documentation or from you -- never from us guessing.\n' >&2
    return 1
  fi
  if [ "$(wt_attached_managed | wc -l | tr -d ' ')" -lt 2 ]; then
    printf '  Not offered: the %s is the only monitor on this computer, so a\n' "$R_NAME" >&2
    printf '  wrong guess would black out the screen you are reading. Use the\n' >&2
    printf "  monitor's own buttons to see which input this computer is on, then\\n" >&2
    printf '  enter that value.\n' >&2
    return 1
  fi

  printf '  I will send each standard input value to the %s in turn and ask\n' "$R_NAME" >&2
  printf '  whether it came back. Your other monitor stays on this computer\n' >&2
  printf '  throughout, so you can keep reading this.\n\n' >&2
  printf '  COST: every wrong value moves that panel to another input. If none of\n' >&2
  printf '  them is right it will stay on the last one, and you will need the\n' >&2
  printf "  monitor's own buttons to bring it back.\\n" >&2
  if ! read_yesno '  Go ahead?' n; then return 1; fi

  _j=0
  while [ "$_j" -lt "${#MCCS_VALUES[@]}" ]; do
    printf '\n  Trying %s ...\n' "${MCCS_VALUES[$_j]}" >&2
    wt_send_input "$R_LABEL" "${MCCS_VALUES[$_j]}" "$_cfg"
    sleep "$TK_WALK_HOLD"
    if read_yesno "  Is the $R_NAME showing THIS computer now?" n; then
      printf '\n  Found it: %s is %s on this panel.\n' "${MCCS_VALUES[$_j]}" "${MCCS_NAMES[$_j]}" >&2
      WT_WALK_FOUND=${MCCS_VALUES[$_j]}
      return 0
    fi
    _j=$(( _j + 1 ))
  done

  printf "\\n  None of the standard values brought it back. Use the monitor's buttons\\n" >&2
  printf '  to return it to this computer.\n' >&2
  return 1
}

# --- the trigger -------------------------------------------------------------

# Restore a watcher the trigger check stood down. Run from a RETURN trap, so it
# covers every way out; it reports and still returns 0.
wt_resume_watcher() {
  [ -n "$1" ] || return 0
  if ! tk_bootstrap "$(tk_domain)" "$1"; then
    tk_log "could not restart the watcher this check paused: $TK_BOOTSTRAP_ERR"
    tk_log 'NOTHING IS WATCHING until you run:  trigger-kvm restart'
  fi
  return 0
}

WT_RAN_TRIGGERS=''
WT_TRIGGERS_OK=''
wt_check_triggers() {
  local _pull _tmp _d _rc _paused
  if [ "${#WT_DEVICES[@]}" -eq 0 ]; then
    printf '\n  No trigger devices are chosen yet -- pick some first.\n' >&2
    WT_RAN_TRIGGERS='no devices chosen'; WT_TRIGGERS_OK=0
    return 0
  fi

  _pull=0
  wt_pull_allowed && _pull=1

  printf '\n--- test the trigger ---\n' >&2
  printf '  Flip your switch AWAY from this computer, then back again. The way\n' >&2
  printf '  back is what a trigger is: the devices ARRIVING here.\n' >&2
  if [ "$_pull" = "1" ]; then
    printf '\n  When they do, the monitors will be pulled here for real, using the\n' >&2
    printf '  values you just checked. That is the whole thing working end to end.\n' >&2
  else
    printf '\n  The arrival will be reported but the monitors will NOT be moved:\n' >&2
    printf '  check them first (the row above) and this becomes the real thing.\n' >&2
  fi

  # The installed watcher would see the same flip and pull against the SAVED
  # config. Stand it down where that needs no password, and restore it on every
  # way out; the boot tier is left running and said so (11).
  _paused=''
  case $(tk_installed_tier) in
    login|no)
      if tk_agent_loaded; then
        "$TK_LAUNCHCTL" bootout "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1 || true
        _paused=$(tk_agent_plist)
        printf '\n  The running watcher is paused for this check.\n' >&2
      fi ;;
    boot)
      printf '\n  The running watcher will also fire, using the saved configuration.\n' >&2 ;;
  esac

  _tmp=$(mktemp -t trigger-kvm-trig)
  # shellcheck disable=SC2064
  trap "rm -f '$_tmp'; wt_resume_watcher '$_paused'" RETURN
  wt_write_config "$_tmp"

  set -- --test-trigger
  for _d in "${WT_DEVICES[@]}"; do set -- "$@" --device "$_d"; done
  _rc=0
  "$TK_WATCHER" "$@" >&2 || _rc=$?

  if [ "$_rc" != "0" ]; then
    printf '\n  Nothing arrived, so these may be the wrong devices -- or they may not\n' >&2
    printf '  be on the switch at all. Pick Triggers again to change them.\n' >&2
    WT_RAN_TRIGGERS='no arrival seen'; WT_TRIGGERS_OK=0
    return 0
  fi

  if [ "$_pull" != "1" ]; then
    WT_RAN_TRIGGERS='arrival seen'; WT_TRIGGERS_OK=1
    return 0
  fi

  printf '\n  Pulling the monitors here...\n' >&2
  "$TK_SELF" pull --config "$_tmp" >&2 || true

  printf '\n' >&2
  if read_yesno '  Did the monitors come back to this computer?' y; then
    WT_RAN_TRIGGERS='fired, monitors followed'; WT_TRIGGERS_OK=1
    return 0
  fi
  # A monitors fault with the trigger passing.
  printf '\n  The trigger fired, so the devices are right. Something about the\n' >&2
  printf '  monitors is not -- check them again from the row above.\n' >&2
  WT_RAN_TRIGGERS='fired, but the monitors did not follow'; WT_TRIGGERS_OK=0
  return 0
}
