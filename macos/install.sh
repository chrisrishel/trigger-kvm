#!/bin/bash
#
# Install trigger-kvm on this Mac. Run from the source tree:
#
#     cd macos && ./install.sh
#
# THIS IS WHAT INSTALLING IS, and it is why there is no `install` verb on the
# CLI: installing is what produces the command. Upgrading and repairing both
# mean "fetch the source and run its installer", which works because the install
# is SELF-CONTAINED -- this script copies itself alongside the program, so
# managing and removing keep working after the source tree is gone.
#
# Afterwards it is one command from anywhere:
#
#     trigger-kvm configure     the walkthrough; applies what you changed
#     trigger-kvm status        is it running, what that covers, version
#     trigger-kvm discover      what is attached, in the form the config wants
#     trigger-kvm restart       make a hand-edited config take effect now
#     trigger-kvm logs / pause / uninstall
#
# WHEN IT STARTS is a property of the HOST, not of the switcher, so all of that
# logic lives here. Nothing in trigger-kvm or event-watch knows or asks when it
# was started; if either ever needs to, the abstraction is wrong.
#
# TWO TIERS, and they are mutually exclusive -- installing one removes the other,
# because two live watchers would both fire on the same arrival and the debounce
# is per-process, so it cannot dedupe across them.
#
#   install.autostart = boot    a LaunchDaemon in /Library/LaunchDaemons with
#                               UserName set. Starts at boot, before any login.
#                               Runs AS THE USER, UNELEVATED. sudo ONCE, here,
#                               to install it into the system domain -- nothing
#                               elevated runs on the switch path afterwards.
#   install.autostart = login   a LaunchAgent in ~/Library/LaunchAgents. No
#                               password, ever. Covers everything from login
#                               onward, including while the screen is locked.
#
# Only the boot tier asks for a password, and only while installing. If it
# cannot be obtained -- a headless or non-interactive run -- it falls back to
# login and says so. Nothing elevates without someone choosing it.

set -euo pipefail

SRC=$(cd -P "$(dirname "$0")" && pwd)

# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

VERB=${1:-install}

case $VERB in
  uninstall) ;;
  install)   ;;
  *) printf 'usage: %s [install|uninstall]\n' "$0" >&2; exit 2 ;;
esac

say() { printf 'install: %s\n' "$*"; }

DOMAIN="gui/$(id -u)"

# --- uninstall ---------------------------------------------------------------

if [ "$VERB" = "uninstall" ]; then
  launchctl bootout "$DOMAIN/$TK_LABEL" >/dev/null 2>&1 || true
  rm -f "$TK_PLIST" && say "removed $TK_PLIST"
  if [ -f "$TK_DAEMON_PLIST" ]; then
    say "removing the boot-tier LaunchDaemon needs your password once."
    sudo launchctl bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
    sudo rm -f "$TK_DAEMON_PLIST" && say "removed $TK_DAEMON_PLIST"
  fi
  rm -f "$TK_BINDIR/trigger-kvm"
  rm -rf "$TK_PREFIX" && say "removed $TK_PREFIX"
  # The log and the config are LEFT IN PLACE. The log is the only record of what
  # happened, and a config can represent real work -- reinstalling should not
  # make you redo it. Both live outside the program directory for exactly this
  # reason.
  say 'uninstalled.'
  say "config and log kept: $TK_SUPPORT/config"
  exit 0
fi

# --- build -------------------------------------------------------------------

if ! command -v clang >/dev/null 2>&1; then
  say 'clang not found. Install the Xcode command line tools: xcode-select --install'
  exit 1
fi

say 'building'
make -C "$SRC" -s all

if [ ! -x "${M1DDC:-/opt/homebrew/bin/m1ddc}" ]; then
  say "m1ddc not found at ${M1DDC:-/opt/homebrew/bin/m1ddc}."
  say 'Install it with:  brew install m1ddc'
  say 'Continuing -- everything else installs, but a switch will refuse until it is there.'
fi

# --- copy --------------------------------------------------------------------

mkdir -p "$TK_PREFIX/lib" "$TK_BINDIR" "$TK_SUPPORT" "$(dirname "$TK_LOG")"

install -m 755 "$SRC/trigger-kvm"   "$TK_PREFIX/trigger-kvm"
install -m 755 "$SRC/event-watch"   "$TK_PREFIX/event-watch"
install -m 755 "$SRC/display-probe" "$TK_PREFIX/display-probe"
install -m 644 "$SRC"/lib/*.sh      "$TK_PREFIX/lib/"
# Itself, so uninstalling works after the source tree is gone.
install -m 755 "$0"                 "$TK_PREFIX/install.sh"

# What is running, and how old it is. `status` prints this, because "am I
# running what I think I am running?" is otherwise unanswerable -- the installed
# copy is what `trigger-kvm` resolves to, NOT the source tree you just edited,
# and a stale install looks exactly like a missing feature.
{
  printf 'version = %s\n' "$TK_VERSION"
  printf 'installed = %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'spec-revision = %s\n' \
    "$(sed -n 's/^revision[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SRC/SPEC-REVISION" 2>/dev/null | tail -1)"
  printf 'commit = %s\n' \
    "$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'source = %s\n' "$SRC"
} > "$TK_PREFIX/version.txt"
say "installed to $TK_PREFIX"

# ONLY a directory holding the launcher goes on PATH -- one symlink, never the
# program directory, which would publish every file in it as a command.
ln -sf "$TK_PREFIX/trigger-kvm" "$TK_BINDIR/trigger-kvm"
say "linked $TK_BINDIR/trigger-kvm"

# --- the LaunchAgent ---------------------------------------------------------
#
# It runs `trigger-kvm watch`, which reads the config and execs the watcher. NO
# configuration is baked in here: which devices to watch and the timings all
# live in the config, and an edit takes effect on the next `trigger-kvm
# restart`. That is why there is no apply step.
#
# KeepAlive is the self-heal. Windows needs a 1-minute repeating trigger for
# this; launchd does it properly, in about a fifth of a second -- measured.

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

# A malformed plist fails SILENTLY at load, so it is verified before anything is
# asked to load it.
if ! plutil -lint "$TK_PLIST" >/dev/null; then
  say "the generated plist is malformed: $TK_PLIST"
  exit 1
fi

# --- configure, if there is nothing to install from --------------------------
#
# No config means nothing to install FROM: values describe one specific desk and
# would be wrong for anyone else. Walk the user through it instead.

CONFIG="$TK_SUPPORT/config"
if [ ! -f "$CONFIG" ]; then
  say 'no configuration yet -- starting the walkthrough.'
  if [ ! -t 0 ]; then
    say 'configure needs a terminal.'
    say "Edit the config directly instead:  $CONFIG"
    say 'Then:  trigger-kvm restart'
    exit 2
  fi
  "$TK_PREFIX/trigger-kvm" configure || exit $?
  exit 0
fi

# --- start -------------------------------------------------------------------

TIER=$(sed -n 's/^[[:space:]]*install\.autostart[[:space:]]*=[[:space:]]*//p' "$CONFIG" | tail -1)

# Whichever tier is chosen, the OTHER one goes. Two live watchers would both
# fire on the same arrival.
launchctl bootout "$DOMAIN/$TK_LABEL" >/dev/null 2>&1 || true

if [ "$TIER" = "boot" ]; then
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
    say 'the generated LaunchDaemon is malformed; not installing it.'
    rm -f "$TMP_DAEMON"
    exit 1
  fi

  say 'starting before login needs your password once, to install it.'
  say 'Nothing runs as an administrator afterwards.'
  if sudo -p 'Password (once, to install the boot-time start): ' \
          install -o root -g wheel -m 644 "$TMP_DAEMON" "$TK_DAEMON_PLIST" 2>/dev/null; then
    rm -f "$TMP_DAEMON"
    sudo launchctl bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
    sudo launchctl bootstrap system "$TK_DAEMON_PLIST"
    say "installed the boot-time start, running as $(id -un), unelevated"
  else
    # Nothing elevates without someone choosing it. Fall back and SAY SO --
    # silently downgrading a tier is how someone discovers months later that
    # switching does nothing until they log in.
    rm -f "$TMP_DAEMON"
    say 'no password given -- falling back to starting at login.'
    say 'Re-run this and choose "From boot" to try again.'
    TIER=login
    sed -i '' 's/^\([[:space:]]*install\.autostart[[:space:]]*=[[:space:]]*\).*/\1login/' "$CONFIG"
  fi
fi

if [ "$TIER" != "boot" ]; then
  # The boot tier owns the daemon; anything else must not leave one behind.
  if [ -f "$TK_DAEMON_PLIST" ]; then
    say 'removing the previous boot-time start needs your password once.'
    sudo launchctl bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
    sudo rm -f "$TK_DAEMON_PLIST" || true
  fi
  if [ "$TIER" = "no" ]; then
    # The agent is installed but not loaded; `restart` loads it. It does not
    # come back after a reboot until then, which is what "no" means.
    say 'autostart is off; the agent is installed but not loaded.'
    say 'start it with:  trigger-kvm restart'
  else
    launchctl bootstrap "$DOMAIN" "$TK_PLIST"
    say 'loaded the LaunchAgent'
  fi
fi

# --- what is left to say -----------------------------------------------------
#
# Short. It runs, here is how to see that, here are four commands. Everything
# else -- how it starts, sessions, the transport -- is in the docs for the day
# someone needs it, and is noise on the day they do not.

case ":$PATH:" in
  *":$TK_BINDIR:"*) CMD=trigger-kvm ;;
  *)                CMD="$TK_BINDIR/trigger-kvm" ;;
esac

printf '\n'
case $TIER in
  no)
    printf '  Done. trigger-kvm is installed, but will NOT come back after a restart --\n'
    printf '  start it yourself with:  %s restart\n' "$CMD" ;;
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
printf '    %s status      is it running?\n'                 "$CMD"
printf '    %s pull        bring the displays here now\n'    "$CMD"
printf '    %s logs        what has it been doing\n'         "$CMD"
printf '    %s configure   change any of this\n'             "$CMD"
printf '\n'
