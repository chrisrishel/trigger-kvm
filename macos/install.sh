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
# shellcheck source=lib/config.sh
. "$SRC/lib/config.sh"
# shellcheck source=lib/manage.sh
. "$SRC/lib/manage.sh"

VERB=${1:-install}

case $VERB in
  uninstall) ;;
  install)   ;;
  *) printf 'usage: %s [install|uninstall]\n' "$0" >&2; exit 2 ;;
esac

say() { printf 'install: %s\n' "$*"; }

DOMAIN="gui/$(id -u)"

# Neither verb may run as root: install would write a root daemon and root-owned
# files, uninstall would delete inside root's home. See tk_refuse_root.
tk_refuse_root || exit 2

# --- the pre-rename install --------------------------------------------------
#
# This was called display-switch until 2026-08-30. An install from before the
# rename left a LaunchAgent under the old label running a watcher called
# usb-watch, and nothing removed it -- so it kept firing its own switcher on
# every flip beside the new one (two watchers, the condition AGENTS.md forbids),
# and after its switcher was deleted it kept failing to spawn it. Removed on
# install and on uninstall; the old log is left, as logs are. Delete this block
# once no machine can plausibly still have one.
OLD_LABEL="com.chrisrishel.displayswitch"
remove_prerename_install() {
  "$TK_LAUNCHCTL" bootout "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1 || true
  for _old in "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" \
              "$TK_BINDIR/usb-watch" "$TK_BINDIR/switch-displays.sh"; do
    if [ -e "$_old" ]; then rm -f "$_old" && say "removed the pre-rename $_old"; fi
  done
}
remove_prerename_install

# --- uninstall ---------------------------------------------------------------

if [ "$VERB" = "uninstall" ]; then
  "$TK_LAUNCHCTL" bootout "$DOMAIN/$TK_LABEL" >/dev/null 2>&1 || true
  rm -f "$TK_PLIST" && say "removed $TK_PLIST"
  if [ -f "$TK_DAEMON_PLIST" ]; then
    say "removing the boot-tier LaunchDaemon needs your password once."
    sudo "$TK_LAUNCHCTL" bootout "system/$TK_LABEL" >/dev/null 2>&1 || true
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

# --- preflight ---------------------------------------------------------------
#
# Everything a stranger's Mac can lack is checked BEFORE anything is built or
# copied, so "this will not work here" is the first thing said, not the last.
# Each stop leaves the machine exactly as it was.

refuse() { say "$@"; say 'Nothing was installed.'; exit 1; }

if ! command -v clang >/dev/null 2>&1; then
  refuse 'clang not found. Install the Xcode command line tools: xcode-select --install'
fi

# m1ddc, which does the DDC writing, supports Apple Silicon only.
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  refuse "this Mac is $ARCH. m1ddc, the tool that talks to the monitors, supports Apple Silicon only."
fi

if [ ! -x "${M1DDC:-/opt/homebrew/bin/m1ddc}" ]; then
  refuse "m1ddc not found at ${M1DDC:-/opt/homebrew/bin/m1ddc}. Install it with:  brew install m1ddc"
fi

# --- build -------------------------------------------------------------------

say 'building'
make -C "$SRC" -s all

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
#
# The tier work and the closing words live in lib/manage.sh, because
# `configure` has to do exactly the same things and there must be one
# implementation of each. Applying is a CONSEQUENCE of configuring, not
# something a user invokes -- which is why there is no apply verb on the CLI.

tk_apply_tier
tk_say_done
