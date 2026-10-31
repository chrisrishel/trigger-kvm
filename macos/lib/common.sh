# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# Paths, logging and the text helpers every verb needs.

TK_LABEL="com.chrisrishel.trigger-kvm"
TK_SUPPORT="$HOME/Library/Application Support/trigger-kvm"
TK_LOG="$HOME/Library/Logs/trigger-kvm.log"

# The installed copy, and the one directory that goes on PATH. Only the
# launcher symlink is published, never the program directory.
TK_PREFIX="$HOME/.local/share/trigger-kvm"
TK_BINDIR="$HOME/.local/bin"

# One launchd plist per autostart tier. tk_apply_tier writes and removes them,
# and each is overridable so the suite never touches the real one.
TK_DAEMON_PLIST=${TK_DAEMON_PLIST:-/Library/LaunchDaemons/$TK_LABEL.plist}   # boot
TK_PLIST=${TK_PLIST:-$HOME/Library/LaunchAgents/$TK_LABEL.plist}             # login
TK_SESSION_PLIST=${TK_SESSION_PLIST:-$TK_PREFIX/$TK_LABEL.plist}             # no: this session only

# launchd is reached through this one name, so the suite can point it at a
# recorder. tests/conventions.tests.sh scans for a bare launchctl.
TK_LAUNCHCTL=${TK_LAUNCHCTL:-/bin/launchctl}

TK_VERSION="0.3.0"

# To stderr, never stdout: stdout carries `list --raw` rows and captured
# results, and a log line there is a row the caller misreads.
tk_log() { printf '%s trigger-kvm: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# "LG, ASUS and DELL", from one name per line.
tk_join_names() {
  awk '
    { n++; name[n] = $0 }
    END {
      if (n == 0) { print ""; exit }
      if (n == 1) { print name[1]; exit }
      out = name[1]
      for (i = 2; i < n; i++) out = out ", " name[i]
      print out " and " name[n]
    }
  '
}

tk_lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }

# Pad or cut to a width in CHARACTERS: printf's %-*s counts bytes, and a curly
# apostrophe in a device name is three of them.
tk_pad() {
  local _s _w _n
  _s=$1 _w=$2
  _n=$(printf '%s' "$_s" | wc -m | tr -d ' ')
  if [ "$_n" -gt "$_w" ]; then
    printf '%s' "$(printf '%s' "$_s" | cut -c "1-$_w")"
  else
    printf '%s%*s' "$_s" "$(( _w - _n ))" ''
  fi
}
