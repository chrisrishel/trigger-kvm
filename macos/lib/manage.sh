# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# discover, status, restart, pause, logs, watch -- everything about the watcher
# and the install rather than about moving a monitor.
#
# WHEN IT STARTS IS A PROPERTY OF THE HOST, not of the switcher. Nothing in
# lib/display.sh knows or asks when it was started, and if it ever needs to the
# abstraction is wrong -- stop and rethink rather than adding the branch.

# --- discover ----------------------------------------------------------------

# What is attached, in the form the config wants.
#
# Devices come from `event-watch --list` rather than being enumerated again
# here. That program owns the question "is that device here?", and a second
# implementation would be free to disagree with the one that actually fires --
# which is the worst possible place for a disagreement, since this list is what
# someone picks their trigger from.
cmd_discover() {
  local _cur _rows _kind _key _state _name _mark
  printf '\n=== displays on this computer ===\n'
  RAW=0 cmd_list_table

  printf '\n=== devices that could be a trigger ===\n\n'
  echo 'The trigger is whatever MOVES when you flip the switch. Pick the ones that'
  echo 'travel; USB rows are what is attached right now, Bluetooth rows what is paired.'
  printf '\n'

  _cur=$(config_trigger_devices | tr '\n' ' ')
  _rows=$("$TK_WATCHER" --list 2>/dev/null || true)
  if [ -z "$_rows" ]; then
    echo '  (none found)'
  else
    printf '%s\n' "$_rows" | while IFS='|' read -r _kind _key _state _name; do
      _mark=''
      case " $_cur " in *" $_key "*) _mark='  <- currently a trigger' ;; esac
      printf '  %-22s %-4s %-24s %s%s\n' "$_key" "$(printf '%s' "$_kind" | tr '[:lower:]' '[:upper:]')" \
             "$_state" "$_name" "$_mark"
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

# --- the watcher ---------------------------------------------------------------

# Run the watcher in the foreground, configured from the config file. This is
# what the LaunchAgent starts.
#
# `exec`, not a call: the shell is REPLACED by the watcher, so there is no
# wrapper process in between. On Windows the watcher is a grandchild of the
# scheduled task, which means stopping the task kills only the shim and leaves
# the watcher holding the lock -- a trap that has caught people repeatedly.
# There is deliberately no equivalent here to fall into.
cmd_watch() {
  local _devices _d _deb _set
  _devices=$(config_trigger_devices)
  if [ -z "$_devices" ]; then
    tk_log "no trigger.device in $CONFIG -- run: trigger-kvm configure"
    exit 2
  fi

  set -- --exec "$TK_SELF" --arg pull --log "$TK_LOG"
  for _d in $_devices; do set -- "$@" --device "$_d"; done

  _deb=$(config_get 'trigger.debounce'); [ -n "$_deb" ] && set -- "$@" --debounce "$_deb"
  _set=$(config_get 'trigger.settle');   [ -n "$_set" ] && set -- "$@" --settle "$_set"

  mkdir -p "$(dirname "$TK_LOG")"
  exec "$TK_WATCHER" "$@"
}

# --- launchd -------------------------------------------------------------------

tk_domain() { printf 'gui/%s\n' "$(id -u)"; }

tk_agent_loaded() { launchctl print "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1; }

cmd_restart() {
  # The boot tier lives in the system domain, which needs a password to bounce.
  if [ -f "$TK_DAEMON_PLIST" ]; then
    tk_log 'restarting the boot-time start needs your password once.'
    sudo launchctl bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
    sudo launchctl bootstrap system "$TK_DAEMON_PLIST" >/dev/null 2>&1 || true
    sleep 1
    tk_log 'restarted; the watcher has re-read the config.'
    exit 0
  fi
  if [ ! -f "$TK_PLIST" ]; then
    tk_log "not installed: $TK_PLIST is missing. Run the installer from the source tree."
    exit 1
  fi
  launchctl bootout "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$(tk_domain)" "$TK_PLIST" >/dev/null 2>&1 || true
  sleep 1
  if tk_agent_loaded; then
    tk_log 'restarted; the watcher has re-read the config.'
    exit 0
  fi
  tk_log 'restarted, but no watcher came up -- check: trigger-kvm logs'
  exit 1
}

# Stand the watcher down so one can be run by hand.
#
# `bootout` rather than `kill`: KeepAlive would restart a killed watcher within
# about a hundredth of a second, so killing it is not standing it down. That is
# the same trap the Windows side documents about stopping a scheduled task, in
# the platform's own terms.
cmd_pause() {
  if [ -f "$TK_DAEMON_PLIST" ]; then
    tk_log 'standing down the boot-time start needs your password once.'
    sudo launchctl bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
  fi
  launchctl bootout "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1 || true
  tk_log 'paused: the agent is unloaded and the watcher stopped.'
  tk_log 'run one by hand now, e.g.:'
  tk_log "    $TK_ROOT/event-watch --exec /bin/echo --arg TEST --device usb:046d:0843 --verbose"
  tk_log 'then restore with:  trigger-kvm restart'
  exit 0
}

cmd_logs() {
  if [ ! -f "$TK_LOG" ]; then
    printf 'no log yet at %s\n' "$TK_LOG"
    exit 1
  fi
  exec tail -n 50 -f "$TK_LOG"
}

# --- status --------------------------------------------------------------------

# Which tier is actually installed, read from the system rather than from the
# config: the config records what was ASKED for, and these record what is there.
tk_installed_tier() {
  if [ -f "$TK_DAEMON_PLIST" ]; then printf 'boot\n'
  elif [ -f "$TK_PLIST" ];      then printf 'login\n'
  else                               printf 'none\n'; fi
}

cmd_status() {
  local _n _note _labels _this _machines _c _v _when _rev _commit
  # Say when it runs and what that therefore COVERS -- never just a tier name.
  # What someone wants to know is whether a locked or logged-out machine still
  # follows the switch.
  case $(tk_installed_tier) in
    boot)
      printf 'autostart: at boot  (LaunchDaemon %s)\n' "$TK_LABEL"
      printf '           covers: from boot onward -- before anyone logs in, while\n'
      printf '           locked, and after logout\n'
      printf '           runs as: %s, unelevated. Your password installed it; it\n' "$(id -un)"
      printf '           does not run anything as an administrator.\n'
      ;;
    login)
      if tk_agent_loaded; then
        printf 'autostart: when you log in  (LaunchAgent %s)\n' "$TK_LABEL"
        printf '           covers: from login onward, including while the screen is LOCKED\n'
        printf '           NOT covered: before you log in, and after you log out\n'
        printf '           to cover those too:  trigger-kvm configure  -> Autostart -> From boot\n'
      else
        printf 'autostart: installed but NOT loaded -- start it with: trigger-kvm restart\n'
      fi
      ;;
    *)
      printf 'autostart: not installed\n'
      ;;
  esac

  # `|| true`: pgrep exits 1 when nothing matches, and under `set -euo pipefail`
  # that made `status` stop dead at this line on a machine with no watcher --
  # which is exactly the machine someone runs `status` on.
  _n=$(pgrep -f 'event-watch --exec' 2>/dev/null | wc -l | tr -d ' ' || true)
  [ -n "$_n" ] || _n=0
  if [ "$_n" = "1" ]; then _note=''; else _note='  <- expected exactly 1'; fi
  printf 'watchers : %s%s\n' "$_n" "$_note"
  printf 'log      : %s\n' "$TK_LOG"
  if [ -f "$CONFIG" ]; then _note=''; else _note='  <- MISSING; run: trigger-kvm configure'; fi
  printf 'config   : %s%s\n' "$CONFIG" "$_note"
  # From the INSTALLED stamp, not from the constant compiled into whichever copy
  # happens to be running -- the whole point is to show what is deployed.
  if [ -f "$TK_PREFIX/version.txt" ]; then
    _v=$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p'       "$TK_PREFIX/version.txt" | tail -1)
    _when=$(sed -n 's/^installed[[:space:]]*=[[:space:]]*//p'  "$TK_PREFIX/version.txt" | tail -1)
    _rev=$(sed -n 's/^spec-revision[[:space:]]*=[[:space:]]*//p' "$TK_PREFIX/version.txt" | tail -1)
    _commit=$(sed -n 's/^commit[[:space:]]*=[[:space:]]*//p'   "$TK_PREFIX/version.txt" | tail -1)
    printf 'version  : %s   spec revision %s\n' "${_v:-?}" "${_rev:-?}"
    printf 'installed: %s   from commit %s\n' "${_when:-?}" "${_commit:-?}"
  else
    printf 'version  : %s   <- installed before version stamping\n' "$TK_VERSION"
  fi
  printf 'program  : %s%s\n' "$TK_ROOT" \
    "$([ "$TK_ROOT" = "$TK_PREFIX" ] || printf '  <- NOT the installed copy')"

  case ":$PATH:" in
    *":$TK_BINDIR:"*) printf 'path     : %s (on PATH)\n' "$TK_BINDIR" ;;
    *) printf 'path     : %s  <- not on PATH\n' "$TK_BINDIR" ;;
  esac

  _labels=$(config_display_labels | tr '\n' ' ')
  _this=$(config_this_computer)
  printf 'displays : %s\n' "${_labels:-none configured}"
  _machines=$(config_known_computers | while IFS= read -r _c; do
                if [ "$_c" = "$_this" ]; then printf '%s (this one) ' "$_c"; else printf '%s ' "$_c"; fi
              done)
  if [ -n "$_machines" ]; then
    printf 'computers: %s  (trigger-kvm to <name>; only pull is automatic)\n' "$_machines"
  else
    printf 'computers: none\n'
  fi
  printf 'triggers : %s\n' "$(config_trigger_devices | tr '\n' ' ' | sed 's/ $//')"
  exit 0
}
