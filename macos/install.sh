#!/bin/bash
#
# Install trigger-kvm on this Mac, from the source tree:
#
#     cd macos && ./install.sh
#     ./install.sh uninstall        remove the program; keep the config and log
#
# Installing is what produces the command, so there is no `install` verb;
# upgrading and repairing both mean running this again. The install is
# self-contained: this script copies itself alongside the program, so
# uninstalling works after the source tree is gone.
#
# When the watcher starts is a property of the host (../specs/configure.md 8):
#
#   install.autostart = boot    LaunchDaemon with UserName set, as the user,
#                               unelevated. sudo once, here, to install it.
#   install.autostart = login   LaunchAgent in ~/Library/LaunchAgents.
#   install.autostart = no      loaded now, for this session only.
#
# Only the boot tier asks for a password, and if it cannot be obtained it falls
# back to login and says so.

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

# Neither verb may run as root: install would write a root daemon and
# root-owned files, uninstall would delete inside root's home.
tk_refuse_root || exit 2

# An install from before this project was renamed (display-switch, with a
# watcher called usb-watch) is removed, so two watchers cannot both fire.
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
  # The log is the only record of what happened, and a config is real work.
  say 'uninstalled.'
  say "config and log kept: $TK_SUPPORT/config"
  exit 0
fi

# --- preflight ---------------------------------------------------------------
#
# Everything a Mac can lack is checked before anything is built or copied.

refuse() { say "$@"; say 'Nothing was installed.'; exit 1; }

if ! command -v clang >/dev/null 2>&1; then
  refuse 'clang not found. Install the Xcode command line tools: xcode-select --install'
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  refuse "this Mac is $ARCH. m1ddc, the tool that talks to the monitors, supports Apple Silicon only."
fi

if [ ! -x "${M1DDC:-/opt/homebrew/bin/m1ddc}" ]; then
  refuse "m1ddc not found at ${M1DDC:-/opt/homebrew/bin/m1ddc}. Install it with:  brew install m1ddc"
fi

# --- build and copy ----------------------------------------------------------

say 'building'
make -C "$SRC" -s all

mkdir -p "$TK_PREFIX/lib" "$TK_BINDIR" "$TK_SUPPORT" "$(dirname "$TK_LOG")"

install -m 755 "$SRC/trigger-kvm"   "$TK_PREFIX/trigger-kvm"
install -m 755 "$SRC/event-watch"   "$TK_PREFIX/event-watch"
install -m 755 "$SRC/display-probe" "$TK_PREFIX/display-probe"
install -m 644 "$SRC"/lib/*.sh      "$TK_PREFIX/lib/"
install -m 755 "$0"                 "$TK_PREFIX/install.sh"

# What is installed and how old it is; `status` prints it, because the
# installed copy is what `trigger-kvm` resolves to, not the source tree.
{
  config_line 'version'   "$TK_VERSION"
  config_line 'installed' "$(date '+%Y-%m-%d %H:%M:%S')"
  config_line 'spec-revision' \
    "$(sed -n 's/^revision[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SRC/SPEC-REVISION" 2>/dev/null | tail -1)"
  config_line 'commit' \
    "$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  config_line 'source' "$SRC"
} > "$TK_PREFIX/version.txt"
say "installed to $TK_PREFIX"

# One symlink on PATH, never the program directory.
ln -sf "$TK_PREFIX/trigger-kvm" "$TK_BINDIR/trigger-kvm"
say "linked $TK_BINDIR/trigger-kvm"

# --- configure, or start -----------------------------------------------------

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

tk_apply_tier
tk_say_done
