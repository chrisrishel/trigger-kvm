# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# The two checks, and the only part of this program that deliberately moves a
# monitor while someone is watching.
#
# WHAT IS UNDER TEST IS THE CLAIM THAT INPUT V OF PANEL P IS COMPUTER C. A panel
# that answers every command perfectly while its inputs are mapped to the wrong
# computers fails this and is not broken. Hence "test the monitor inputs".
#
# A SWITCH IS CONFIRMED BY A HUMAN LOOKING AT IT. Never by a return code and
# never by reading a VCP value back -- reads lie on both panels here, and have
# already produced false negatives. Every question below is asked about
# something the person just watched.

# How long a panel is held on the candidate input before it is brought back,
# and how long to let the return settle. Eight seconds is the point on hardware
# -- it is what someone needs to look up, see the switch, and look back -- and
# dead weight in a test, so the suite turns them down rather than sleeping for
# minutes.
TK_HOLD=${TK_HOLD:-8}
TK_SETTLE_BACK=${TK_SETTLE_BACK:-2}
TK_WALK_HOLD=${TK_WALK_HOLD:-6}

# The ONE place a check moves a monitor. Everything that switches a panel goes
# through here -- a batched round, a single retry, a blind walk -- so there is a
# single line to read when asking "what can send a packet?", and a single thing
# for a test harness to stand in for.
wt_send_input() {
  "$TK_SELF" set --only "$1" --value "$2" --config "$3" >/dev/null 2>&1 || true
}

# What the monitor's own menu calls an input value, so recovery instructions can
# say "choose HDMI 1" rather than "choose 0x11". Nobody's OSD shows hex.
wt_input_name() {
  local _i
  # The channel's own table only, never the map: a computer name like "pc" is
  # what THIS tool calls an input, and the monitor's menu has never heard of it.
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

# Prove the display answers BEFORE anything is written, against a throwaway
# config. The switcher takes its map from a config file rather than the command
# line -- deliberately, so a panel has one description and not two -- so testing
# early means writing a temp one, not weakening the rule that nothing is written
# until you save.
wt_check_displays() {
  local _tmp _scope _i _scoped _others _c _bad _skipped _target _panels _np
  local _nscoped _rounds _head _last _old _round _f
  _tmp=$(mktemp -t trigger-kvm-check)
  # shellcheck disable=SC2064
  trap "rm -f '$_tmp'" RETURN
  wt_write_config "$_tmp"

  # Which monitor to check -- their intent, not the tool's convenience. It used
  # to ask where this window was so it could schedule that panel last; the same
  # protection comes from saying what is about to move and letting someone act
  # on it, which is one fewer question and one they could not answer
  # confidently anyway.
  _scope=''
  if [ "${#WT_A_KEY[@]}" -gt 1 ]; then
    printf '\n  Which monitor do you want to check?\n' >&2
    menu_reset
    menu_add 'All of them' ''
    _i=0
    while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do menu_add "${WT_A_NAME[$_i]}" ''; _i=$(( _i + 1 )); done
    select_one --default 0 --escapable
    if [ "$MENU_PICK" -lt 0 ]; then
      WT_RAN_DISPLAYS='not checked'; WT_DISPLAYS_OK=0; return 0
    fi
    [ "$MENU_PICK" -gt 0 ] && _scope=$(( MENU_PICK - 1 ))
  fi

  # The panels in scope, as indices.
  _scoped=''
  if [ -n "$_scope" ]; then _scoped=$_scope
  else
    _i=0
    while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do _scoped="$_scoped $_i"; _i=$(( _i + 1 )); done
  fi

  # Every other computer any scoped panel claims.
  _others=''
  for _i in $_scoped; do
    for _c in $(map_computers "${WT_A_MAP[$_i]}"); do
      [ "$_c" = "$WT_THIS" ] && continue
      case " $_others " in *" $_c "*) ;; *) _others="$_others $_c" ;; esac
    done
  done

  _bad=''
  _skipped=0

  if [ -z "$_others" ]; then
    # Nothing else is on this desk, so there is no claim to check beyond "the
    # transport reaches each panel".
    for _i in $_scoped; do
      if ! wt_check_one "$_i" '' "$_tmp"; then _bad="$_bad
${WT_A_NAME[$_i]}"; fi
    done
  fi

  for _target in $_others; do
    # Panels that know BOTH this computer and the target.
    _panels=''
    for _i in $_scoped; do
      if [ -n "$(map_get "${WT_A_MAP[$_i]}" "$_target")" ] &&
         [ -n "$(map_get "${WT_A_MAP[$_i]}" "$WT_THIS")" ]; then
        _panels="$_panels $_i"
      fi
    done
    [ -n "$_panels" ] || continue

    # HARD RULE 4: one panel always stays on this computer, so the question
    # arrives on a screen you can still read. When every panel being checked
    # claims this computer, that means TWO ROUNDS -- the second covers the one
    # held back.
    _np=$(printf '%s' "$_panels" | wc -w | tr -d ' ')
    _nscoped=$(printf '%s' "$_scoped" | wc -w | tr -d ' ')
    _rounds=''
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
      # NEWLINE-separated, not space: a panel is called "LG ULTRAGEAR+", and a
      # space-separated list turned that into two failures called "LG" and
      # "ULTRAGEAR+" in the row someone reads to find out what went wrong.
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

  # Declining is not a failure and must not read as a pass either.
  if [ "$_skipped" = "1" ]; then
    WT_RAN_DISPLAYS='not checked'; WT_DISPLAYS_OK=0; return 0
  fi
  _bad=$(printf '%s' "$_bad" | grep -v '^$' || true)
  if [ -n "$_bad" ]; then
    WT_RAN_DISPLAYS="trouble with $(printf '%s' "$_bad" | tk_join_names)"
    WT_DISPLAYS_OK=0
  else
    WT_RAN_DISPLAYS='all responded'
    WT_DISPLAYS_OK=1
  fi
  return 0
}

# One round: send a group of panels to one computer together, bring them all
# back, and ask ONCE.
#
# BATCHED ACROSS PANELS, NEVER ACROSS COMPUTERS. Monitors sit side by side, so
# several are confirmed in one glance; a SEQUENCE over half a minute has to be
# held in memory and reported afterwards, and memory is the weak link.
#
# The win is the question, not the wall clock. Asking "did they all show pc?"
# makes the common case -- everything worked -- one keystroke, and the four-way
# diagnosis only appears for the panels someone says went wrong.
WT_ROUND_BAD=''
WT_ROUND_SKIPPED=0
wt_check_round() {
  local _round _target _cfg _hold _names _i _namelist _stays _staylist _n
  local _verb _solo _back _bname _count _q _wrong _idx _p
  _round=$1 _target=$2 _cfg=$3 _hold=${4:-$TK_HOLD}
  WT_ROUND_BAD=''
  WT_ROUND_SKIPPED=0

  _names=''
  for _i in $_round; do _names="$_names
${WT_A_NAME[$_i]}"; done
  _namelist=$(printf '%s' "${_names#
}" | tk_join_names)

  # WHAT STAYS is measured against EVERY MANAGED PANEL, not just this round's:
  # a panel nobody asked to check is still on this computer, and still somewhere
  # to put a window.
  _stays=''
  _i=0
  while [ "$_i" -lt "${#WT_A_KEY[@]}" ]; do
    case " $_round " in
      *" $_i "*) ;;
      *) _stays="$_stays
${WT_A_NAME[$_i]}" ;;
    esac
    _i=$(( _i + 1 ))
  done

  printf '\n  Sending %s to %s for %ss, then back automatically.\n' "$_namelist" "$_target" "$_hold" >&2
  printf '  If %s is asleep or off you will see No Signal, which still proves the\n' "$_target" >&2
  printf '  switch worked.\n' >&2

  if [ -n "$_stays" ]; then
    _staylist=$(printf '%s' "${_stays#
}" | tk_join_names)
    _n=$(printf '%s' "${_stays#
}" | grep -c . || true)
    if [ "$_n" -eq 1 ]; then _verb=stays; else _verb=stay; fi
    printf '\n  %s %s here, so you can read this.\n' "$_staylist" "$_verb" >&2
    # TOLD EVERY ROUND rather than asked once. This cannot see where the window
    # is, and asking made someone answer a question about the tool's
    # scheduling; saying what is about to move lets them act on it only if it
    # applies.
    printf '  If this window is on %s, drag it to %s first: if the switch back\n' \
           "$_namelist" "$(printf '%s' "${_stays#
}" | head -1)" >&2
    printf '  fails, the window goes dark with it and there is no way to answer.\n' >&2
    # Last, and blocking: it is the thing to act on, so nothing may print after
    # it and be read too late.
    menu_read_line '  Enter when ready' '' >/dev/null || menu_eof
  else
    # ONE MONITOR AND NOTHING TO HOLD BACK. If the switch back fails, this
    # person is looking at a black screen with no way to read a prompt, ask a
    # question or undo anything. That is unavoidable -- but being stranded
    # WITHOUT HAVING BEEN TOLD how to get back is not, and the telling has to
    # happen while there is still a screen to read it on.
    _solo=$(printf '%s' "$_round" | awk '{print $1}')
    _back=$(map_get "${WT_A_MAP[$_solo]}" "$WT_THIS")
    _bname=$(wt_input_name "${WT_A_METHOD[$_solo]}" "$_back")
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
    wt_send_input "${WT_A_LABEL[$_i]}" "$(map_get "${WT_A_MAP[$_i]}" "$_target")" "$_cfg"
  done
  sleep "$_hold"
  for _i in $_round; do
    wt_send_input "${WT_A_LABEL[$_i]}" "$(map_get "${WT_A_MAP[$_i]}" "$WT_THIS")" "$_cfg"
  done
  sleep "$TK_SETTLE_BACK"

  printf '\n' >&2
  _count=$(printf '%s' "$_round" | wc -w | tr -d ' ')
  if [ "$_count" -eq 1 ]; then _q="  Did $_namelist show $_target, then come back?"
  else _q="  Did all of them show $_target, then come back?"; fi
  if read_yesno "$_q" y; then return 0; fi

  # Only now does anyone have to think. One panel needs no narrowing question.
  _wrong=$_round
  if [ "$_count" -gt 1 ]; then
    printf '\n  Which ones did not?\n' >&2
    menu_reset
    for _i in $_round; do menu_add "${WT_A_NAME[$_i]}" "${WT_A_LABEL[$_i]}"; done
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
      WT_ROUND_BAD="$WT_ROUND_BAD
${WT_A_NAME[$_i]}"
    fi
  done
  WT_ROUND_BAD=$(printf '%s' "$WT_ROUND_BAD" | grep -v '^$' || true)
  return 0
}

# Switch one display to a candidate input, hold, bring it BACK automatically,
# and only then ask.
#
# The return is what makes this safe to run against the display you are reading:
# the question always arrives on a panel that has already come back, so this
# never needs to know which monitor its own window is on, and a wrong guess
# costs a few seconds of black rather than a stranded session.
#
# Asked AS IT HAPPENED, IN THE ORDER IT HAPPENED: did it go, and did it come
# back. One question with four answers made the reader hold every failure in
# mind at once to find their own; this asks the thing they just watched, and
# only the "no" leads anywhere else.
#
# Returns 0 correct, 1 changed to the WRONG thing, 2 went and did not come back,
# 3 nothing happened.
WT_OUTCOME=0
wt_probe_one() {
  local _i _candidate _candname _cfg _hold _name _here _ismachine
  _i=$1 _candidate=$2 _candname=$3 _cfg=$4 _hold=${5:-$TK_HOLD}
  _name=${WT_A_NAME[$_i]}
  _here=$(map_get "${WT_A_MAP[$_i]}" "$WT_THIS")
  _ismachine=$6

  printf '\n  Sending %s to %s for %ss, then back automatically.\n' "$_name" "$_candname" "$_hold" >&2
  if [ "$_ismachine" = "1" ]; then
    printf '  Watch that monitor -- you should see %s on it.\n' "$_candname" >&2
    printf '  If that computer is asleep or off it will say No Signal, which still\n' >&2
    printf '  proves the switch worked.\n' >&2
  else
    printf '  Watch that monitor. It only has to CHANGE -- if nothing is plugged into\n' >&2
    printf '  that input it will say No Signal, and that still proves the switch worked.\n' >&2
  fi

  wt_send_input "${WT_A_LABEL[$_i]}" "$_candidate" "$_cfg"
  sleep "$_hold"
  if [ -n "$_here" ]; then wt_send_input "${WT_A_LABEL[$_i]}" "$_here" "$_cfg"; sleep "$TK_SETTLE_BACK"; fi

  printf '\n  Did the %s change to %s, and back to %s?\n' "$_name" "$_candname" "$WT_THIS" >&2
  menu_reset
  menu_add "Yes, and it changed back to $WT_THIS"     'everything works'
  menu_add "Yes, but it did not change back to $WT_THIS" "the input for $WT_THIS is wrong"
  menu_add 'No' ''
  select_one --default 0
  case $MENU_PICK in
    0) WT_OUTCOME=0; return 0 ;;
    1) WT_OUTCOME=2; return 0 ;;
  esac

  # Only a "no" needs taking apart, and only when there was a computer to
  # expect: testing a bare input value, any change at all proves the transport,
  # so there is nothing left to ask.
  if [ "$_ismachine" != "1" ]; then WT_OUTCOME=3; return 0; fi

  printf '\n  Did the %s change at all?\n' "$_name" >&2
  menu_reset
  menu_add "Yes, but it was not $_candname" "that input is not $_candname"
  menu_add 'No, nothing happened'           'this panel does not answer on this channel'
  select_one --default 1
  if [ "$MENU_PICK" = "0" ]; then WT_OUTCOME=1; else WT_OUTCOME=3; fi
  return 0
}

# One panel, one computer: send it there, bring it back, act on what the human
# saw. Fixes retry IN PLACE, because bouncing out to the review menu to change
# one value and come back is a worse way to say "try that again".
#
# ONE RETRY PER FIX, then take the answer. Do not loop.
wt_check_one() {
  local _i _target _cfg _attempt _here _cand _candname _j _vendor _di _what
  local _keep _c _allownone _alt _to _offer
  _i=$1 _target=$2 _cfg=$3 _attempt=${4:-1}

  # Write before every attempt: escalating to a dialect changes the method, and
  # the switcher reads the method from the file.
  wt_write_config "$_cfg"

  _here=$(map_get "${WT_A_MAP[$_i]}" "$WT_THIS")
  if [ -n "$_target" ]; then
    wt_probe_one "$_i" "$(map_get "${WT_A_MAP[$_i]}" "$_target")" "$_target" "$_cfg" "$TK_HOLD" 1
  else
    # Nothing else is on this panel, so there is no claim to check beyond "the
    # transport reaches it". Any other input value will do.
    wt_input_table "${WT_A_METHOD[$_i]}" "${WT_A_MAP[$_i]}"
    _cand='' _candname=''
    _j=0
    while [ "$_j" -lt "${#IT_VALUES[@]}" ]; do
      if [ "$(tk_lower "${IT_VALUES[$_j]}")" != "$(tk_lower "$_here")" ]; then
        _cand=${IT_VALUES[$_j]}; _candname=${IT_NAMES[$_j]}; break
      fi
      _j=$(( _j + 1 ))
    done
    [ -n "$_cand" ] || return 0
    wt_probe_one "$_i" "$_cand" "$_candname" "$_cfg" "$TK_HOLD" 0
  fi

  [ "$WT_OUTCOME" = "0" ] && return 0
  [ "$_attempt" -ge 2 ] && return 1     # bounded: one retry per fix

  # 1: the panel obeys and the value for this computer is right -- that input is
  # just not the computer we thought.
  if [ "$WT_OUTCOME" = "1" ] && [ -n "$_target" ]; then
    printf '\n  So that input is not %s. Which one is?\n' "$_target" >&2
    wt_read_input "${WT_A_METHOD[$_i]}" "${WT_A_MAP[$_i]}" \
      "On the ${WT_A_NAME[$_i]}, which input is '$_target' on?" '' \
      "$(map_get "${WT_A_MAP[$_i]}" "$_target")" "$_target" 1
    if [ "$WT_INPUT_NONE" = "1" ]; then
      WT_A_MAP[_i]=$(map_del "${WT_A_MAP[$_i]}" "$_target")
      return 0
    fi
    WT_A_MAP[_i]=$(map_set "${WT_A_MAP[$_i]}" "$_target" "$WT_INPUT_VALUE")
    wt_check_one "$_i" "$_target" "$_cfg" $(( _attempt + 1 ))
    return $?
  fi

  # 2: the panel obeys, so the channel is right; the value for THIS computer is
  # not.
  if [ "$WT_OUTCOME" = "2" ]; then
    printf '\n  So %s responds -- the channel is right. The input for this\n' "${WT_A_NAME[$_i]}" >&2
    printf "  computer is not. Use that monitor's own buttons to bring it back,\\n" >&2
    printf '  then tell me which input that is.\n\n' >&2
    if read_yesno '  Do you know which input it is?' y; then
      wt_read_input "${WT_A_METHOD[$_i]}" "${WT_A_MAP[$_i]}" \
        "On the ${WT_A_NAME[$_i]}, which input is '$WT_THIS' on?" '' "$_here" "$WT_THIS" 0
      WT_A_MAP[_i]=$(map_set "${WT_A_MAP[$_i]}" "$WT_THIS" "$WT_INPUT_VALUE")
    else
      if ! wt_blind_walk "$_i" "$_cfg"; then return 1; fi
      WT_A_MAP[_i]=$(map_set "${WT_A_MAP[$_i]}" "$WT_THIS" "$WT_WALK_FOUND")
    fi
    wt_check_one "$_i" "$_target" "$_cfg" $(( _attempt + 1 ))
    return $?
  fi

  # 3: nothing at all. The channel is wrong. This is where a method change is
  # OFFERED -- offered, from documented values, never probed.
  #
  # SYMMETRIC, because specs/configure.md section 6.2 lets someone choose the
  # manufacturer method up front: a panel can arrive here already on it, and
  # telling that person "no manufacturer values are known" would be false and a
  # dead end. So a panel on standard is offered the manufacturer method, and a
  # panel on the manufacturer method is offered standard.
  _vendor=$(printf '%s' "${WT_A_KEY[$_i]}" | cut -d: -f1)
  if _di=$(wt_dialect_for "$_vendor"); then
    _what=${DIALECT_WHAT[$_di]}
    _alt=${DIALECT_METHOD[$_di]}

    if [ "${WT_A_METHOD[$_i]}" != "$_alt" ]; then
      _to=$_alt
      printf '\n  %s did not answer the standard channel. It is %s, and some %s\n' \
             "${WT_A_NAME[$_i]}" "$_what" "$_what" >&2
      printf '  panels put input switching on a manufacturer channel instead. These\n' >&2
      printf '  values are documented for %s, and are the only ones that will be\n' "$_what" >&2
      printf '  sent -- nothing is guessed at on a manufacturer channel:\n\n' >&2
      _offer="Yes, try the $_what channel"
    else
      _to=standard
      printf '\n  %s is on %s'"'"'s own method and did not answer it. The standard method\n' \
             "${WT_A_NAME[$_i]}" "$_what" >&2
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

    # A menu, like every other decision in the walkthrough. This used to be the
    # last y/n confirm left, which made the most consequential question in the
    # program look like the least considered.
    menu_reset
    menu_add "$_offer" 'and say which input each computer is on'
    menu_add 'No, leave this monitor out' 'everything else stays configured'
    select_one --default 0 --escapable
    if [ "$MENU_PICK" = "0" ]; then
      # Every value in the old map was for a channel that does not work, so the
      # map starts again rather than carrying meaningless numbers across.
      WT_A_METHOD[_i]=$_to
      _keep=$(map_computers "${WT_A_MAP[$_i]}")
      WT_A_MAP[_i]=''
      for _c in $_keep; do
        _allownone=1
        [ "$_c" = "$WT_THIS" ] && _allownone=0
        wt_read_input "${WT_A_METHOD[$_i]}" "${WT_A_MAP[$_i]}" \
          "On the ${WT_A_NAME[$_i]}, which input is '$_c' on?" '' '' "$_c" "$_allownone"
        [ "$WT_INPUT_NONE" = "1" ] || WT_A_MAP[_i]=$(map_set "${WT_A_MAP[$_i]}" "$_c" "$WT_INPUT_VALUE")
      done
      wt_check_one "$_i" "$_target" "$_cfg" $(( _attempt + 1 ))
      return $?
    fi
    return 1
  fi

  printf '\n  %s did not answer the standard channel, and no manufacturer values\n' "${WT_A_NAME[$_i]}" >&2
  printf '  are known here for %s. That panel may not support DDC/CI input\n' \
         "$(printf '%s' "${WT_A_KEY[$_i]}" | cut -d: -f1)" >&2
  printf '  switching at all, or may use a channel nobody has documented.\n\n' >&2
  printf '  Everything else is still configured; this monitor just will not follow\n' >&2
  printf '  the switch. Leave it out with Monitors -> "Manage this monitor? no".\n' >&2
  return 1
}

# Last resort: send each standard input value in turn until the panel comes back
# to this computer.
#
# STANDARD DDC/CI ONLY, MCCS values only, one at a time, and NEVER on a
# manufacturer sidechannel, where a value we have not been told is a value
# nobody should send. Offered, never automatic, and the cost is stated first.
WT_WALK_FOUND=''
wt_blind_walk() {
  local _i _cfg _j
  _i=$1 _cfg=$2
  WT_WALK_FOUND=''

  printf '\n--- try the standard values one at a time ---\n' >&2
  if [ "${WT_A_METHOD[$_i]}" != "standard" ]; then
    printf '  Only offered on the standard channel. A manufacturer channel takes\n' >&2
    printf '  values from documentation or from you -- never from us guessing.\n' >&2
    return 1
  fi
  # HARD RULE 4. With nothing else on this computer, a wrong guess blacks out
  # the screen this question is printed on.
  if [ "${#WT_A_KEY[@]}" -lt 2 ]; then
    printf '  Not offered: the %s is the only monitor on this computer, so a\n' "${WT_A_NAME[$_i]}" >&2
    printf '  wrong guess would black out the screen you are reading. Use the\n' >&2
    printf "  monitor's own buttons to see which input this computer is on, then\\n" >&2
    printf '  enter that value.\n' >&2
    return 1
  fi

  printf '  I will send each standard input value to the %s in turn and ask\n' "${WT_A_NAME[$_i]}" >&2
  printf '  whether it came back. Your other monitor stays on this computer\n' >&2
  printf '  throughout, so you can keep reading this.\n\n' >&2
  printf '  COST: every wrong value moves that panel to another input. If none of\n' >&2
  printf '  them is right it will stay on the last one, and you will need the\n' >&2
  printf "  monitor's own buttons to bring it back.\\n" >&2
  if ! read_yesno '  Go ahead?' n; then return 1; fi

  _j=0
  while [ "$_j" -lt "${#MCCS_VALUES[@]}" ]; do
    printf '\n  Trying %s ...\n' "${MCCS_VALUES[$_j]}" >&2
    wt_send_input "${WT_A_LABEL[$_i]}" "${MCCS_VALUES[$_j]}" "$_cfg"
    sleep "$TK_WALK_HOLD"
    if read_yesno "  Is the ${WT_A_NAME[$_i]} showing THIS computer now?" n; then
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

# Checked AFTER the monitor inputs, and that ordering is the point: once the
# input values are confirmed, the flip BACK can pull the monitors for real, so
# it stops being "an event was observed" and becomes the whole thing working.
wt_check_triggers() {
  local _pull _tmp _d _rc
  if [ "${#WT_DEVICES[@]}" -eq 0 ]; then
    printf '\n  No trigger devices are chosen yet -- pick some first.\n' >&2
    WT_RAN_TRIGGERS='no devices chosen'; WT_TRIGGERS_OK=0
    return 0
  fi

  _pull=0
  [ "$WT_DISPLAYS_OK" = "1" ] && _pull=1

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

  # A throwaway config, for the same reason the monitor check uses one: the
  # answers are not written yet, and pulling against the SAVED config would move
  # the panels to whatever was configured before rather than to what is on
  # screen now.
  _tmp=$(mktemp -t trigger-kvm-trig)
  # shellcheck disable=SC2064
  trap "rm -f '$_tmp'" RETURN
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
  # A "no" here is a MONITORS fault with the trigger passing, which is a
  # different diagnosis from "nothing arrived".
  printf '\n  The trigger fired, so the devices are right. Something about the\n' >&2
  printf '  monitors is not -- check them again from the row above.\n' >&2
  WT_RAN_TRIGGERS='fired, but the monitors did not follow'; WT_TRIGGERS_OK=0
  return 0
}
