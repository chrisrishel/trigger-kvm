# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# The watcher and the install: watch, launchd, the autostart tiers, restart,
# pause, logs, status. When the watcher starts is a property of the host and
# lives here; nothing in the switcher knows or asks.

# --- the watcher ---------------------------------------------------------------

# Run the watcher in the foreground, configured from the config file. This is
# what launchd starts. `exec`, so no shell sits between launchd and the lock.
cmd_watch() {
  local _devices _bad _d _deb _set
  # Refused by name, never defaulted (specs/detector.md 4). Under KeepAlive a
  # refusal repeats every few seconds in the log, which is the point.
  _bad=$(config_bad_trigger_devices)
  if [ -n "$_bad" ]; then
    tk_log "REFUSING to watch: trigger.device has an entry that is not usb:VVVV:PPPP or bt:AAAAAAAAAAAA: $(printf '%s' "$_bad" | tr '\n' ' ')"
    exit 2
  fi
  _devices=$(config_trigger_devices)
  if [ -z "$_devices" ]; then
    tk_log "no trigger.device in $CONFIG -- run: trigger-kvm configure"
    exit 2
  fi
  _deb=$(config_get 'trigger.debounce')
  _set=$(config_get 'trigger.settle')
  if [ -n "$_deb" ] && ! config_is_seconds "$_deb"; then
    tk_log "REFUSING to watch: trigger.debounce = '$_deb' is not a number of seconds like 3 or 0.75"
    exit 2
  fi
  if [ -n "$_set" ] && ! config_is_seconds "$_set"; then
    tk_log "REFUSING to watch: trigger.settle = '$_set' is not a number of seconds like 3 or 0.75"
    exit 2
  fi

  set -- --exec "$TK_SELF" --arg pull --log "$TK_LOG"
  for _d in $_devices; do set -- "$@" --device "$_d"; done
  [ -n "$_deb" ] && set -- "$@" --debounce "$_deb"
  [ -n "$_set" ] && set -- "$@" --settle "$_set"

  mkdir -p "$(dirname "$TK_LOG")"
  exec "$TK_WATCHER" "$@"
}

# --- launchd -------------------------------------------------------------------

tk_domain() { printf 'gui/%s\n' "$(id -u)"; }

# Nothing here runs as root. Under sudo, `id -un` is root, so the boot daemon
# would run as root on a user-writable config and every file created would be
# root-owned.
tk_refuse_root() {
  if [ "$(id -u)" -eq 0 ]; then
    tk_log 'run this as yourself, not with sudo.'
    tk_log 'It asks for your password itself if you choose to start from boot, and nothing it installs runs as root.'
    return 1
  fi
  return 0
}

tk_agent_loaded() { "$TK_LAUNCHCTL" print "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1; }

# Is a watcher running? From the lock, never by counting processes
# (specs/status.md 2). The query exits 1 when nothing holds it.
tk_watcher_running() { [ "$("$TK_WATCHER" --lock-status 2>/dev/null || true)" = running ]; }

# Load a plist into a domain, replacing whatever is loaded there.
#
# THE ONE DOOR INTO launchd, and its failure is caught, never thrown: the
# bootout runs first, so between the two calls nothing is watching, and every
# caller runs under `set -e`. Elevation follows from the domain. The bootout is
# best-effort (it fails when nothing is loaded); the bootstrap's answer is the
# one that means something, and its reason is left in TK_BOOTSTRAP_ERR.
TK_BOOTSTRAP_ERR=''
tk_bootstrap() {
  local _domain _plist _rc
  _domain=$1; _plist=$2; _rc=0
  TK_BOOTSTRAP_ERR=''
  if [ "$_domain" = "system" ]; then
    sudo "$TK_LAUNCHCTL" bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
    TK_BOOTSTRAP_ERR=$(sudo "$TK_LAUNCHCTL" bootstrap system "$_plist" 2>&1) || _rc=$?
  else
    "$TK_LAUNCHCTL" bootout "$_domain/$TK_LABEL" >/dev/null 2>&1 || true
    TK_BOOTSTRAP_ERR=$("$TK_LAUNCHCTL" bootstrap "$_domain" "$_plist" 2>&1) || _rc=$?
  fi
  return "$_rc"
}

# Which tier is installed, read from what is on disk rather than from the
# config: the config records what was asked for, these record what is there.
tk_installed_tier() {
  if   [ -f "$TK_DAEMON_PLIST" ];  then printf 'boot\n'
  elif [ -f "$TK_PLIST" ];         then printf 'login\n'
  elif [ -f "$TK_SESSION_PLIST" ]; then printf 'no\n'
  else                                  printf 'none\n'; fi
}

# The user-domain plist of the installed tier, if any.
tk_agent_plist() {
  case $(tk_installed_tier) in
    login) printf '%s\n' "$TK_PLIST" ;;
    no)    printf '%s\n' "$TK_SESSION_PLIST" ;;
  esac
}

cmd_restart() {
  local _plist
  if [ -f "$TK_DAEMON_PLIST" ]; then
    tk_log 'restarting the boot-time start needs your password once.'
    if ! tk_bootstrap system "$TK_DAEMON_PLIST"; then
      tk_log "could not start the boot-time watcher: $TK_BOOTSTRAP_ERR"
      tk_log 'NOTHING IS WATCHING. The daemon is still installed, so a reboot'
      tk_log 'will start it; to try again now:  trigger-kvm restart'
      exit 1
    fi
    sleep 1
    tk_log 'restarted; the watcher has re-read the config.'
    exit 0
  fi
  _plist=$(tk_agent_plist)
  if [ -z "$_plist" ]; then
    tk_log "not installed: $TK_PLIST is missing. Run the installer from the source tree."
    exit 1
  fi
  if ! tk_bootstrap "$(tk_domain)" "$_plist"; then
    tk_log "could not load the LaunchAgent: $TK_BOOTSTRAP_ERR"
    tk_log 'NOTHING IS WATCHING -- check: trigger-kvm logs'
    exit 1
  fi
  sleep 1
  if tk_agent_loaded; then
    tk_log 'restarted; the watcher has re-read the config.'
    exit 0
  fi
  tk_log 'restarted, but no watcher came up -- check: trigger-kvm logs'
  exit 1
}

# Stand the watcher down so one can be run by hand. `bootout`, never kill:
# KeepAlive restarts a killed watcher in a fifth of a second.
cmd_pause() {
  local _devices
  if [ -f "$TK_DAEMON_PLIST" ]; then
    tk_log 'standing down the boot-time start needs your password once.'
    sudo "$TK_LAUNCHCTL" bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
  fi
  "$TK_LAUNCHCTL" bootout "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1 || true
  sleep 0.3
  tk_watcher_running && { tk_log 'a watcher is STILL RUNNING; nothing was stood down. Check: trigger-kvm status'; exit 1; }
  _devices=$(config_trigger_devices | sed 's/^/--device /' | tr '\n' ' ')
  [ -n "$_devices" ] || _devices='--device usb:VVVV:PPPP '
  tk_log 'paused: NOTHING IS WATCHING until you run:  trigger-kvm restart'
  tk_log 'to run one by hand meanwhile:'
  tk_log "    $TK_ROOT/event-watch --exec /bin/echo --arg TEST --verbose $_devices"
  exit 0
}

cmd_logs() {
  if [ ! -f "$TK_LOG" ]; then
    printf 'no log yet at %s\n' "$TK_LOG"
    exit 1
  fi
  exec tail -n 50 -f "$TK_LOG"
}

# --- the autostart tiers -------------------------------------------------------

# Is the running copy older than the tree it was installed from? Said wherever
# the symptom shows, because a stale install looks exactly like a missing
# feature. Silent when the source tree is gone or matches.
tk_warn_if_stale() {
  local _src _was _now _dirty
  [ -f "$TK_PREFIX/version.txt" ] || return 0
  _src=$(sed -n 's/^source[[:space:]]*=[[:space:]]*//p' "$TK_PREFIX/version.txt" | tail -1)
  _was=$(sed -n 's/^commit[[:space:]]*=[[:space:]]*//p' "$TK_PREFIX/version.txt" | tail -1)
  [ -n "$_src" ] && [ -d "$_src" ] || return 0
  _now=$(git -C "$_src" rev-parse --short HEAD 2>/dev/null) || return 0
  [ -n "$_now" ] || return 0
  _dirty=$(git -C "$_src" status --porcelain -- "$_src" 2>/dev/null | head -1)

  if [ "$_now" != "$_was" ]; then
    tk_log "NOTE: you are running the copy installed from $_was, but"
    tk_log "      $_src is now at $_now."
  elif [ -n "$_dirty" ]; then
    tk_log "NOTE: $_src has uncommitted changes that are not installed."
  else
    return 0
  fi
  tk_log "      Re-run:  cd $_src && ./install.sh"
  return 0
}

# A user-domain agent plist at $1. It runs `trigger-kvm watch`, which reads the
# config and execs the watcher, so nothing is baked in and an edit takes effect
# on the next restart. KeepAlive is the self-heal.
tk_write_agent_plist() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$TK_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$TK_PREFIX/trigger-kvm</string>
    <string>watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$TK_LOG</string>
  <key>StandardErrorPath</key><string>$TK_LOG</string>
</dict></plist>
EOF
  # A malformed plist fails silently at load.
  if ! plutil -lint "$1" >/dev/null; then
    tk_log "the generated LaunchAgent is malformed; not loading it: $1"
    rm -f "$1"
    return 1
  fi
  return 0
}

# Make launchd match install.autostart. One implementation for install.sh and
# `configure`. Leaves the tier that landed in TK_TIER_APPLIED and whether a
# watcher is loaded now in TK_TIER_LOADED, for tk_say_done to claim only what
# was reached (specs/configure.md 12).
TK_TIER_APPLIED=''
TK_TIER_LOADED=0
tk_apply_tier() {
  local CONFIG TMP_DAEMON DOMAIN _why _plist
  tk_refuse_root || return 1
  DOMAIN="$(tk_domain)"
  CONFIG="${1:-$TK_SUPPORT/config}"
  TK_TIER_LOADED=0
  [ -f "$CONFIG" ] || { TK_TIER_APPLIED=''; return 0; }
  config_load "$CONFIG"
  TK_TIER_APPLIED=$(tk_lower "$(config_get install.autostart)")

  # Whichever tier is chosen, the others go: two live watchers would both fire
  # on the same arrival, and a launchd label is per domain.
  "$TK_LAUNCHCTL" bootout "$DOMAIN/$TK_LABEL" >/dev/null 2>&1 || true

  if [ "$TK_TIER_APPLIED" = "boot" ]; then
    # UserName is what makes this run as the user: root installs it, root does
    # not run it.
    TMP_DAEMON=$(mktemp -t trigger-kvm-daemon)
    cat > "$TMP_DAEMON" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$TK_LABEL</string>
  <key>UserName</key><string>$(id -un)</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>ProgramArguments</key><array>
    <string>$TK_PREFIX/trigger-kvm</string>
    <string>watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$TK_LOG</string>
  <key>StandardErrorPath</key><string>$TK_LOG</string>
</dict></plist>
EOF
    if ! plutil -lint "$TMP_DAEMON" >/dev/null; then
      tk_log 'the generated LaunchDaemon is malformed; not installing it.'
      rm -f "$TMP_DAEMON"
      return 1
    fi

    tk_log 'starting before login needs your password once, to install it.'
    tk_log 'Nothing runs as an administrator afterwards.'
    # Either failure falls back to login and says so; the fallback branch below
    # then removes a daemon plist launchd refused, so `status` cannot report a
    # tier that is not running.
    _why=''
    if ! sudo -p 'Password (once, to install the boot-time start): ' \
              install -o root -g wheel -m 644 "$TMP_DAEMON" "$TK_DAEMON_PLIST" 2>/dev/null; then
      _why='no password given'
    elif ! tk_bootstrap system "$TK_DAEMON_PLIST"; then
      _why="launchd would not load it: $TK_BOOTSTRAP_ERR"
    fi
    rm -f "$TMP_DAEMON"

    if [ -z "$_why" ]; then
      tk_log "installed the boot-time start, running as $(id -un), unelevated"
      rm -f "$TK_PLIST" "$TK_SESSION_PLIST"
      TK_TIER_LOADED=1
    else
      tk_log "$_why -- falling back to starting at login."
      tk_log 'Re-run this and choose "From boot" to try again.'
      TK_TIER_APPLIED=login
      sed -i '' 's/^\([[:space:]]*install\.autostart[[:space:]]*=[[:space:]]*\).*/\1login/' "$CONFIG"
    fi
  fi

  if [ "$TK_TIER_APPLIED" != "boot" ]; then
    if [ -f "$TK_DAEMON_PLIST" ]; then
      tk_log 'removing the previous boot-time start needs your password once.'
      sudo "$TK_LAUNCHCTL" bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
      sudo rm -f "$TK_DAEMON_PLIST" || true
    fi
    # "No" keeps the plist out of ~/Library/LaunchAgents, so nothing returns at
    # the next login; loading it now is what starts it for this session.
    if [ "$TK_TIER_APPLIED" = "no" ]; then
      _plist=$TK_SESSION_PLIST; rm -f "$TK_PLIST"
    else
      _plist=$TK_PLIST; rm -f "$TK_SESSION_PLIST"
    fi
    tk_write_agent_plist "$_plist" || return 1
    if ! tk_bootstrap "$DOMAIN" "$_plist"; then
      # Over SSH there is no gui domain to load into.
      tk_log "could not load the LaunchAgent now: $TK_BOOTSTRAP_ERR"
      if [ "$TK_TIER_APPLIED" = "no" ]; then
        tk_log 'Nothing is watching; to start it:  trigger-kvm restart'
      else
        tk_log 'That is normal over SSH -- there is no login session to load into.'
        tk_log 'It starts at your next login; to start it sooner:  trigger-kvm restart'
      fi
    else
      tk_log 'loaded the LaunchAgent'
      TK_TIER_LOADED=1
    fi
  fi
  return 0
}

# The closing words, from one place for install.sh and `configure`. Claims only
# the state tk_apply_tier reached.
tk_say_done() {
  local _cmd
  case ":$PATH:" in
    *":$TK_BINDIR:"*) _cmd=trigger-kvm ;;
    *)                _cmd="$TK_BINDIR/trigger-kvm" ;;
  esac
  printf '\n'
  case "$TK_TIER_APPLIED/$TK_TIER_LOADED" in
    boot/*)
      printf '  Done. trigger-kvm is running, and will start each time the computer\n'
      printf '  starts -- before anyone logs in.\n' ;;
    login/1)
      printf '  Done. trigger-kvm is running, and will start automatically each time you\n'
      printf '  log in.\n' ;;
    login/*)
      printf '  Done. trigger-kvm is installed and starts at your next login. To start\n'
      printf '  it now:  %s restart\n' "$_cmd" ;;
    no/1)
      printf '  Done. trigger-kvm is running, for this session only. It will NOT come\n'
      printf '  back after a restart or a new login -- start it then with:  %s restart\n' "$_cmd" ;;
    *)
      printf '  Done. trigger-kvm is installed but NOT running -- start it with:  %s restart\n' "$_cmd" ;;
  esac
  printf '\n'
  printf '  Flip your switch to this computer -- the monitors should follow.\n'
  printf '\n'
  printf '    %s status      is it running?\n'                 "$_cmd"
  printf '    %s pull        bring the displays here now\n'    "$_cmd"
  printf '    %s logs        what has it been doing\n'         "$_cmd"
  printf '    %s configure   change any of this\n'             "$_cmd"
  printf '\n'
}

# --- status --------------------------------------------------------------------

# specs/status.md. Never sends a packet or reads a VCP value.
cmd_status() {
  local _note _labels _this _machines _c _v _l _row _first _when _rev _commit
  local _all _vn _pn _n _d _args _key _verdict
  tk_warn_if_stale
  # What the tier COVERS, not just its name: whether a locked or logged-out
  # computer still follows the switch is the question.
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
    no)
      printf 'autostart: no  (started by hand, for this session only)\n'
      printf '           NOT covered: after a restart or a new login. Start it then with:\n'
      printf '           trigger-kvm restart\n'
      ;;
    *)
      printf 'autostart: not installed\n'
      ;;
  esac

  if tk_watcher_running; then
    printf 'watcher  : running\n'
  else
    printf 'watcher  : none  <- nothing is watching; start it with: trigger-kvm restart\n'
  fi
  printf 'log      : %s\n' "$TK_LOG"
  if [ -f "$CONFIG" ]; then _note=''; else _note='  <- MISSING; run: trigger-kvm configure'; fi
  printf 'config   : %s%s\n' "$CONFIG" "$_note"
  # From the installed stamp, which is what is deployed.
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

  # specs/status.md 4.1: the watcher's own verdict per entry. A port that
  # decided a match is said; an ambiguous entry is a trigger that never fires.
  _args=()
  for _d in $(config_trigger_devices); do _args+=(--device "$_d"); done
  if [ "${#_args[@]}" -gt 0 ]; then
    while IFS='|' read -r _key _verdict _n; do
      [ -n "$_key" ] || continue
      case $_verdict in
        where)
          printf '           %s  <- the remembered port decided which device this is\n' "$_key" ;;
        ambiguous)
          printf '           %s  <- DISABLED: %s present devices match and none is at\n' "$_key" "$_n"
          printf '              the remembered port. Re-run: trigger-kvm configure\n' ;;
      esac
    done <<EOF
$("$TK_WATCHER" --report "${_args[@]}" 2>/dev/null || true)
EOF
  fi

  # specs/status.md 3: the input map, and the claim nothing can make. The map
  # asserts physical cabling; a cable moved on the monitor leaves `pull`
  # switching that panel to a dead input with a success in the log.
  if [ -z "$_labels" ]; then
    printf 'inputs   : none configured\n'
  else
    _first=y
    for _l in $_labels; do
      # Ordered by computer, in the order they were listed (3.1).
      _row=''
      for _c in $(config_known_computers); do
        _v=$(config_input_for "$_l" "$_c")
        [ -n "$_v" ] || continue
        if [ "$_c" = "$_this" ]; then _c="$_c (this one)"; fi
        if [ "$_v" = AMBIGUOUS ]; then
          _row="$_row, two inputs both name $_c -- fix the config"
        else
          _row="$_row, $(printf '0x%02X' "$_v") -> $_c"
        fi
      done
      _row=${_row#, }
      [ -n "$_row" ] || _row='no inputs configured'
      if [ "$_first" = y ]; then
        printf 'inputs   : %-8s %s\n' "$_l" "$_row"; _first=n
      else
        printf '           %-8s %s\n' "$_l" "$_row"
      fi
    done
    # Each normative fragment whole inside one printf: the conformance check
    # reads this source.
    printf '           ^ asserted, never verified. If a cable moved to another input\n'
    printf '             on the monitor, pull silently switches that panel to a dead input\n'
    printf '             -- black, with a success in the log.  Fix: trigger-kvm configure\n'
  fi

  # specs/status.md 5: a configured identity matching more than one attached
  # panel. The switch has already refused; this is where the person looks.
  # Not for a panel that is merely absent.
  _all=$(display_enumerate 2>/dev/null || true)
  for _l in $_labels; do
    _v=$(config_get "display.$_l.vendor"); _c=$(config_get "display.$_l.product")
    _vn=$(config_to_word "$_v") || continue
    _pn=$(config_to_word "$_c") || continue
    _n=$(display_identity_count "$_all" "$(printf '%04X:%04X' "$_vn" "$_pn")")
    [ "$_n" -gt 1 ] || continue
    # 5.2: no fix is offered, because there is none, and neither panel is named
    # as the one that will be used.
    printf '\n  WARNING: %s -- more than one attached monitor matches its id\n' "$_l"
    printf '  (0x%04X:0x%04X): %s of them do. It has stopped following, because\n' \
      "$_vn" "$_pn" "$_n"
    printf '  the switch refuses rather than guessing which one you meant.\n'
    printf '  Unplugging one is the only remedy today.\n'
  done
  exit 0
}
