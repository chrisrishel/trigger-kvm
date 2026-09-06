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
  local _devices _bad _d _deb _set
  # Refused by name, never defaulted or dropped (specs/detector.md 4). A watcher
  # armed on a mis-parsed entry, or with a debounce that read as zero, runs and
  # never does the right thing -- the worst failure shape available. Refusing
  # under KeepAlive means refusing again every few seconds, loudly in the log,
  # which is the point.
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

# Nothing here may run as root. The boot tier's whole property is that root
# INSTALLS the daemon and the daemon runs as the user (UserName in the plist);
# run under sudo, `id -un` is root, so the daemon would be written to run as
# root on a user-writable config -- a local privilege escalation -- and every
# file the installer creates would be root-owned, so the user's next
# `configure` could not write its own config. `sudo ./install.sh` is the first
# thing a stranger tries, so it is refused, in words, before anything happens.
tk_refuse_root() {
  if [ "$(id -u)" -eq 0 ]; then
    tk_log 'run this as yourself, not with sudo.'
    tk_log 'It asks for your password itself if you choose to start from boot, and nothing it installs runs as root.'
    return 1
  fi
  return 0
}

tk_agent_loaded() { "$TK_LAUNCHCTL" print "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1; }

# Load a plist into a domain, replacing whatever is loaded there.
#
# THE ONE DOOR, and the reason it is one is that this failure must be CAUGHT
# rather than thrown. The bootout runs first, so between the two calls there is
# no watcher at all -- and every caller here runs under `set -euo pipefail`, so
# an unchecked bootstrap aborted mid-window: the daemon installed but not
# loaded, the agent booted out, nothing running, and `tk_installed_tier` still
# reading the plist off disk so `status` went on reporting "at boot". The other
# shape was worse -- `|| true` and then an unconditional "restarted".
# specs/configure.md 4.4: where an interrupted run cannot leave a working setup,
# it has to say what is left.
#
# Elevation is NOT a parameter: the system domain always needs it and a user
# domain never does, so it follows from the domain rather than from a caller
# remembering. The bootout stays best-effort by design -- it fails when nothing
# is loaded, which is the ordinary first-install case. Only the bootstrap's
# answer means anything, and its reason is left in TK_BOOTSTRAP_ERR to print.
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

cmd_restart() {
  # The boot tier lives in the system domain, which needs a password to bounce.
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
  if [ ! -f "$TK_PLIST" ]; then
    tk_log "not installed: $TK_PLIST is missing. Run the installer from the source tree."
    exit 1
  fi
  if ! tk_bootstrap "$(tk_domain)" "$TK_PLIST"; then
    tk_log "could not load the LaunchAgent: $TK_BOOTSTRAP_ERR"
    tk_log 'NOTHING IS WATCHING -- check: trigger-kvm logs'
    exit 1
  fi
  sleep 1
  if tk_agent_loaded; then
    tk_log 'restarted; the watcher has re-read the config.'
    exit 0
  fi
  # launchd accepted the job and it did not come up: a different failure from a
  # refused bootstrap, and worth telling apart.
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
    sudo "$TK_LAUNCHCTL" bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
  fi
  "$TK_LAUNCHCTL" bootout "$(tk_domain)/$TK_LABEL" >/dev/null 2>&1 || true
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

# Is the copy that is RUNNING older than the tree it was installed from?
#
# This exists because the mistake happened twice in one afternoon: a feature was
# built, committed, and then reported missing -- because `trigger-kvm` resolves
# to the installed copy, not to the source tree it was written in. A stale
# install looks EXACTLY like a missing feature, and nothing said so.
#
# Warned about wherever the symptom would show up, not only in `status`, since
# nobody runs `status` to find out why a menu row is wrong. Silent when the
# source tree is gone, is not a git repository, or matches -- all normal.
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


# Make the launchd side match install.autostart, and report which tier landed.
#
# ONE implementation, called by install.sh and by `configure`. configure used to
# end with `exec trigger-kvm restart`, which only bounces the AGENT -- so
# choosing the boot tier wrote `install.autostart = boot` to the config and then
# silently did nothing, never even asking for the password. The config records
# what was asked for; this is what makes the system match it.
TK_TIER_APPLIED=''
# The login tier's LaunchAgent. It runs `trigger-kvm watch`, which reads the
# config and execs the watcher; NO configuration is baked in, so an edit takes
# effect on the next `restart` and there is no apply step. KeepAlive is the
# self-heal -- launchd does it in about a fifth of a second, measured.
#
# Written here, by tk_apply_tier, and nowhere else: the tier that owns launchd
# owns both plists, so choosing boot can remove this one (see below) and
# choosing login can write it back.
tk_write_agent_plist() {
  mkdir -p "$(dirname "$TK_PLIST")"
  cat > "$TK_PLIST" <<EOF
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
  # A malformed plist fails SILENTLY at load, so it is verified before anything
  # is asked to load it.
  if ! plutil -lint "$TK_PLIST" >/dev/null; then
    tk_log "the generated LaunchAgent is malformed; not loading it: $TK_PLIST"
    rm -f "$TK_PLIST"
    return 1
  fi
  return 0
}

# What is left to say after configure or install. Short: it runs, here is how
# to see that, here are four commands. Printed from ONE place for both paths --
# it used to live in the installer only, so a first install (which hands off
# to configure) and every later configure ended without it.
tk_say_done() {
  local _cmd
  case ":$PATH:" in
    *":$TK_BINDIR:"*) _cmd=trigger-kvm ;;
    *)                _cmd="$TK_BINDIR/trigger-kvm" ;;
  esac
  printf '\n'
  case $TK_TIER_APPLIED in
    no)
      printf '  Done. trigger-kvm is installed, but will NOT come back after a restart --\n'
      printf '  start it yourself with:  %s restart\n' "$_cmd" ;;
    boot)
      printf '  Done. trigger-kvm is running, and will start each time the computer\n'
      printf '  starts -- before anyone logs in.\n' ;;
    *)
      printf '  Done. trigger-kvm is running, and will start automatically each time you\n'
      printf '  log in.\n' ;;
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

tk_apply_tier() {
  local CONFIG TMP_DAEMON DOMAIN _why
  tk_refuse_root || return 1
  DOMAIN="$(tk_domain)"
  CONFIG="${1:-$TK_SUPPORT/config}"
  [ -f "$CONFIG" ] || { TK_TIER_APPLIED=''; return 0; }
  # Through the reader, never a private sed. A trailing comment or a capital
  # letter on this line otherwise read as "no tier" -- which removed the boot
  # daemon on the next upgrade while the config still said boot.
  config_load "$CONFIG"
  TK_TIER_APPLIED=$(tk_lower "$(config_get install.autostart)")

  # Whichever tier is chosen, the OTHER one goes. Two live watchers would both
  # fire on the same arrival.
  "$TK_LAUNCHCTL" bootout "$DOMAIN/$TK_LABEL" >/dev/null 2>&1 || true

  if [ "$TK_TIER_APPLIED" = "boot" ]; then
    # UserName is what makes this the Windows tier rather than a root daemon:
    # launchd drops privileges to that user before running it. Root installs it;
    # root does not run it.
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
    # The boot tier can fail to land two ways, and there is ONE answer to both:
    # fall back to login and SAY SO. Silently downgrading a tier is how someone
    # discovers months later that switching does nothing until they log in --
    # and leaving a daemon plist that launchd refused is how `status` comes to
    # report "at boot" with nothing running, since it reads the file's existence.
    _why=''
    if ! sudo -p 'Password (once, to install the boot-time start): ' \
              install -o root -g wheel -m 644 "$TMP_DAEMON" "$TK_DAEMON_PLIST" 2>/dev/null; then
      _why='no password given'
    elif ! tk_bootstrap system "$TK_DAEMON_PLIST"; then
      _why="launchd would not load it: $TK_BOOTSTRAP_ERR"
    fi
    rm -f "$TMP_DAEMON"

    # Falling back is what CLEARS a daemon launchd refused: the branch below
    # removes the daemon plist for any tier that is not boot, so `status` --
    # which reads the file off disk, not launchd -- cannot go on promising
    # coverage from boot with nothing running. Nothing extra to do here.
    if [ -z "$_why" ]; then
      tk_log "installed the boot-time start, running as $(id -un), unelevated"
      # The boot tier owns launchd. A launchd label is per DOMAIN, so a
      # LaunchAgent left in place comes back at the next login beside the
      # daemon and respawns on the lock every ten seconds, forever.
      rm -f "$TK_PLIST"
    else
      tk_log "$_why -- falling back to starting at login."
      tk_log 'Re-run this and choose "From boot" to try again.'
      TK_TIER_APPLIED=login
      sed -i '' 's/^\([[:space:]]*install\.autostart[[:space:]]*=[[:space:]]*\).*/\1login/' "$CONFIG"
    fi
  fi

  if [ "$TK_TIER_APPLIED" != "boot" ]; then
    # The boot tier owns the daemon; anything else must not leave one behind.
    if [ -f "$TK_DAEMON_PLIST" ]; then
      tk_log 'removing the previous boot-time start needs your password once.'
      sudo "$TK_LAUNCHCTL" bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
      sudo rm -f "$TK_DAEMON_PLIST" || true
    fi
    tk_write_agent_plist || return 1
    if [ "$TK_TIER_APPLIED" = "no" ]; then
      # The agent is installed but not loaded; `restart` loads it. It does not
      # come back after a reboot until then, which is what "no" means.
      tk_log 'autostart is off; the agent is installed but not loaded.'
      tk_log 'start it with:  trigger-kvm restart'
    elif tk_bootstrap "$DOMAIN" "$TK_PLIST"; then
      tk_log 'loaded the LaunchAgent'
    else
      # Over SSH there is no gui domain to load into. The config is written and
      # the agent installed; it starts at the next login. Not an error under
      # set -e, which used to abort here with the config already written.
      tk_log "could not load the LaunchAgent now: $TK_BOOTSTRAP_ERR"
      tk_log 'That is normal over SSH -- there is no login session to load into.'
      tk_log 'It starts at your next login; to start it sooner:  trigger-kvm restart'
    fi
  fi


  return 0
}

# Which tier is actually installed, read from the system rather than from the
# config: the config records what was ASKED for, and these record what is there.
tk_installed_tier() {
  if [ -f "$TK_DAEMON_PLIST" ]; then printf 'boot\n'
  elif [ -f "$TK_PLIST" ];      then printf 'login\n'
  else                               printf 'none\n'; fi
}

cmd_status() {
  local _note _labels _this _machines _c _v _l _row _first _when _rev _commit
  tk_warn_if_stale
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

  # specs/status.md 2: answered from the LOCK, never by counting processes.
  # The lock is what makes a second watcher impossible, so it is the authority on
  # both halves of the question -- and because it permits only one, this is a
  # STATE and not a count.
  #
  # Counting worked on this platform and was still the wrong question. Measured
  # 2026-09-06: `pgrep` DOES see a boot-tier watcher from a user session here,
  # because the LaunchDaemon runs as the user, so the Windows blindness that
  # reported `watchers : 0` beside a firing watcher does not reproduce. What it
  # cannot see is a lock held by a process it has no other reason to match --
  # and `-f 'event-watch --exec'` matching on a command line is exactly the
  # brittleness that let a pre-rename watcher run unnoticed for a day.
  #
  # `|| true`: the query exits 1 when nothing holds the lock, and under
  # `set -euo pipefail` that would make `status` stop dead on a machine with no
  # watcher -- which is exactly the machine someone runs `status` on.
  if [ "$("$TK_WATCHER" --lock-status 2>/dev/null || true)" = running ]; then
    printf 'watcher  : running\n'
  else
    printf 'watcher  : none  <- nothing is watching; start it with: trigger-kvm restart\n'
  fi
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

  # specs/status.md 3: the input map, and the one claim this command cannot make.
  #
  # The map is an assertion about PHYSICAL CABLING. If a computer's cable is
  # moved to a different input ON THE MONITOR, a panel whose EDID product id is
  # stable across its inputs still resolves perfectly, `pull` sends the old
  # value, and the panel goes black with a success in the log. Detection is
  # BARRED rather than unimplemented -- reading the value back is hard rule 2 and
  # answers the wrong question anyway -- so making the failure legible is the
  # only move available, which is what makes this wording a behaviour and not a
  # nicety. status.md 3.2: do not hedge it, do not offer to check it.
  #
  # This READS display.<label>.input.<value>; it keeps no second copy of the map.
  if [ -z "$_labels" ]; then
    # 3.1: an empty map asserts nothing, so the warning would be noise.
    printf 'inputs   : none configured\n'
  else
    _first=y
    for _l in $_labels; do
      # 3.1: ordered BY COMPUTER, never by input value. Sorting on the hex puts
      # the same two computers in opposite orders on two panels, purely by which
      # socket each happened to be plugged into -- so the block and the
      # `computers` line above would disagree about the order for no reason.
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
    # Each normative fragment stays whole inside ONE printf. The conformance
    # check reads this source, not the output, so wrapping a fragment across two
    # lines here would render correctly and fail to conform -- and the string it
    # could not find is the one thing this block exists to say.
    printf '           ^ asserted, never verified. If a cable moved to another input\n'
    printf '             on the monitor, pull silently switches that panel to a dead input\n'
    printf '             -- black, with a success in the log.  Fix: trigger-kvm configure\n'
  fi
  exit 0
}
