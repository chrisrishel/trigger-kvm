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
# The login tier's LaunchAgent. Overridable for the same reason the daemon plist
# below is: tk_apply_tier writes and removes it, and the suite must be able to
# point that at a temp file.
TK_PLIST=${TK_PLIST:-$HOME/Library/LaunchAgents/$TK_LABEL.plist}
# The boot tier. A LaunchDaemon in the system domain, but with UserName set so
# it runs AS THE USER, unelevated -- root installs it, root does not run it.
# Overridable so the suite can never touch the real system path. Everything
# else a test needs to fake is already overridable for the same reason.
TK_DAEMON_PLIST=${TK_DAEMON_PLIST:-/Library/LaunchDaemons/$TK_LABEL.plist}
# launchd is reached through this ONE name, never as a bare `launchctl`, so the
# suite can point it at a recorder. The gui domain has no fake path the way the
# daemon plist does: a scripted `configure` that reached Save ran a real
# `launchctl bootout gui/<uid>/<label>` against the developer's live watcher --
# about twenty times per `make test` -- and nothing restored it.
# tests/conventions.tests.sh asserts every invocation goes through here.
TK_LAUNCHCTL=${TK_LAUNCHCTL:-/bin/launchctl}

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
