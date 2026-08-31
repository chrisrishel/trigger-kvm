# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# Paths, logging and the small text helpers every verb needs.

# --- where things live -------------------------------------------------------
#
# One definition each. Three consumers reading the same file from two different
# spellings of its path is the same drift risk as three copies of the parser.

TK_LABEL="com.chrisrishel.trigger-kvm"
TK_SUPPORT="$HOME/Library/Application Support/trigger-kvm"
TK_LOG="$HOME/Library/Logs/trigger-kvm.log"
TK_LOCK="$TK_SUPPORT/watcher.lock"
TK_PLIST="$HOME/Library/LaunchAgents/$TK_LABEL.plist"

# Where an installed copy lives, and where the one symlink that goes on PATH
# points from. Only a directory holding the launcher is published, never the
# program directory: putting that on PATH would publish every file in it as a
# command.
TK_PREFIX="$HOME/.local/share/trigger-kvm"
TK_BINDIR="$HOME/.local/bin"

TK_VERSION="0.2.0"

# --- logging -----------------------------------------------------------------

# TK_LOGFILE is set by the watcher and by a fired switch so their lines land in
# one file in the order they happened. Unset for a manual run, where the
# terminal is what you want.
TK_LOGFILE=${TK_LOGFILE:-}

# To STDERR, not stdout, and that is load-bearing rather than tidy. It is the
# shell's equivalent of PowerShell's Write-Host, which writes to the host and
# deliberately not to the pipeline.
#
# Two things break when a log line goes to stdout. `list --raw` exists so a
# caller can parse the rows, and a log line mixed into them is a row the caller
# silently misreads -- the trap windows/trigger-kvm.ps1 records at its -Raw
# parameter. And a function whose result is captured with $(...) swallows its
# own refusal into the captured value: display_resolve logged "no display
# identifies as it" straight into the variable the caller then treated as a
# resolved panel, so the refusal reached nobody. Found by the tests below.
tk_log() {
  local _line _i
  _line="$(date '+%H:%M:%S') trigger-kvm: $*"
  printf '%s\n' "$_line" >&2
  if [ -n "$TK_LOGFILE" ]; then
    # The watcher appends to the same file, so a write can briefly collide.
    _i=0
    while [ "$_i" -lt 3 ]; do
      if printf '%s\n' "$_line" >>"$TK_LOGFILE" 2>/dev/null; then break; fi
      _i=$(( _i + 1 ))
      sleep 0.05
    done
  fi
}

# --- text --------------------------------------------------------------------

# "LG, ASUS and DELL" rather than "LG and ASUS and DELL". These lines are read
# under mild pressure -- a monitor is about to go dark -- so they should not
# also be awkward.
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
