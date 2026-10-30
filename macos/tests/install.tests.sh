#!/bin/bash
#
# The installer, driven for real against a fake HOME: what it refuses before
# touching anything, what it leaves behind, and what a bare command does.
#
# Nothing here can reach a monitor, launchd or the real install: M1DDC and
# TK_LAUNCHCTL are the harness recorders, TK_DAEMON_PLIST is a temp file, and
# HOME is a temp directory, so every path the installer derives lands there.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_setup
export HOME="$FAKE_DIR/home"
mkdir -p "$HOME"
INSTALL="$MAC_DIR/install.sh"

# Stubs the installer's environment probes. `id` says root; `uname` says Intel.
mkdir -p "$FAKE_DIR/asroot" "$FAKE_DIR/intel"
cat >"$FAKE_DIR/asroot/id" <<'EOS'
#!/bin/sh
case "$1" in -u) echo 0 ;; -un) echo root ;; *) exec /usr/bin/id "$@" ;; esac
EOS
cat >"$FAKE_DIR/intel/uname" <<'EOS'
#!/bin/sh
case "$1" in -m) echo x86_64 ;; *) exec /usr/bin/uname "$@" ;; esac
EOS
chmod +x "$FAKE_DIR/asroot/id" "$FAKE_DIR/intel/uname"

# Run the installer with stdin closed (no terminal), capturing everything.
INST_OUT=""; INST_RC=0
run_install() {
  set +e
  INST_OUT=$("$INSTALL" "$@" </dev/null 2>&1)
  INST_RC=$?
  set -e
}

nothing_installed() {
  assert_true "$([ ! -e "$HOME/.local/share/trigger-kvm" ] && echo 0 || echo 1)" "program directory must not exist: $INST_OUT"
  assert_true "$([ ! -e "$HOME/.local/bin/trigger-kvm" ] && echo 0 || echo 1)" 'launcher must not be linked'
  assert_true "$([ ! -e "$TK_PLIST" ] && echo 0 || echo 1)" 'no LaunchAgent may be written'
  assert_true "$([ ! -e "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" 'no LaunchDaemon may be written'
}

# A config to install FROM, with a chosen tier.
SUPPORT="$HOME/Library/Application Support/trigger-kvm"
write_config_with_tier() {
  mkdir -p "$SUPPORT"
  { printf '%s\n' "$1"; printf '%s' "$CONFIG_THIS_DESK"; } >"$SUPPORT/config"
}

# =============================================================================
# preflight: refuse before touching anything
# =============================================================================

it 'refuses to run as root, and says to run it as yourself'
# The boot tier's property is that root installs the daemon and the daemon runs
# as the user. Under sudo `id -un` is root, so the daemon would run as root on a
# user-writable config, and every file created would be root-owned.
PATH="$FAKE_DIR/asroot:$PATH" run_install
assert_equal 2 "$INST_RC" "$INST_OUT"
assert_match "$INST_OUT" 'not with sudo'
nothing_installed

it 'refuses on a Mac that is not Apple Silicon, naming the reason'
PATH="$FAKE_DIR/intel:$PATH" run_install
assert_equal 1 "$INST_RC" "$INST_OUT"
assert_match "$INST_OUT" 'Apple Silicon only'
assert_match "$INST_OUT" 'x86_64'
nothing_installed

it 'refuses without m1ddc, and says how to get it'
# Warning and carrying on would leave a full install that can only refuse to
# switch, discovered at the first monitor check rather than the first line.
M1DDC="$FAKE_DIR/no-such-m1ddc" run_install
assert_equal 1 "$INST_RC" "$INST_OUT"
assert_match "$INST_OUT" 'brew install m1ddc'
assert_match "$INST_OUT" 'Nothing was installed'
nothing_installed

# =============================================================================
# a first install with no terminal
# =============================================================================

it 'installs the program and the launcher, then asks for a terminal to configure'
run_install
assert_equal 2 "$INST_RC" "$INST_OUT"
assert_match "$INST_OUT" 'configure needs a terminal'
assert_true "$([ -x "$HOME/.local/share/trigger-kvm/trigger-kvm" ] && echo 0 || echo 1)" 'the program is installed'
assert_true "$([ -x "$HOME/.local/share/trigger-kvm/install.sh" ] && echo 0 || echo 1)" 'the installer copies itself'
assert_true "$([ -L "$HOME/.local/bin/trigger-kvm" ] && echo 0 || echo 1)" 'the one launcher symlink exists'
assert_match "$(cat "$HOME/.local/share/trigger-kvm/version.txt")" 'spec-revision = '

it 'the program directory is not on PATH -- only the launcher directory is offered'
assert_no_match "$INST_OUT" 'export PATH'
assert_equal "trigger-kvm" "$(ls "$HOME/.local/bin")"

# =============================================================================
# a re-run over an existing config: the tiers, and what is said at the end
# =============================================================================

fake_sudo_stub

it 'installs the login tier from an existing config and says what to do next'
write_config_with_tier 'install.autostart = login'
: >"$TK_FAKE_LAUNCHCTL"
run_install
assert_equal 0 "$INST_RC" "$INST_OUT"
assert_true "$([ -f "$TK_PLIST" ] && echo 0 || echo 1)" 'the LaunchAgent is written by the tier apply'
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap gui/'
assert_match "$INST_OUT" 'Flip your switch to this computer -- the monitors should follow.'
assert_match "$INST_OUT" 'log in.'

it 'reads the tier through the config reader, so a trailing comment does not lose it'
# The spec's own example line, `install.autostart = boot   # boot | login | no`,
# read by a private sed would be neither tier, and an upgrade would remove the
# boot daemon while the config still said boot.
write_config_with_tier 'Install.Autostart = Boot   # boot | login | no'
: >"$TK_FAKE_LAUNCHCTL"
rm -f "$TK_DAEMON_PLIST"
PATH="$FAKE_DIR/bin:$PATH" run_install
assert_equal 0 "$INST_RC" "$INST_OUT"
assert_true "$([ -f "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" "the boot daemon must be installed: $INST_OUT"
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap system'
assert_match "$INST_OUT" 'before anyone logs in'

it 'and the boot tier leaves no LaunchAgent behind'
assert_true "$([ ! -f "$TK_PLIST" ] && echo 0 || echo 1)" 'a launchd label is per domain; the agent must go'

it 'installs "no" as an agent outside LaunchAgents, loaded for this session only'
# specs/configure.md 8: nothing returns after a restart or a new login.
SESSION_PLIST="$HOME/.local/share/trigger-kvm/com.chrisrishel.trigger-kvm.plist"
write_config_with_tier 'install.autostart = no'
: >"$TK_FAKE_LAUNCHCTL"
PATH="$FAKE_DIR/bin:$PATH" run_install
assert_equal 0 "$INST_RC" "$INST_OUT"
assert_true "$([ ! -f "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" 'the daemon goes'
assert_true "$([ ! -f "$TK_PLIST" ] && echo 0 || echo 1)" 'nothing in LaunchAgents'
assert_true "$([ -f "$SESSION_PLIST" ] && echo 0 || echo 1)" "the agent lives with the program: $INST_OUT"
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" "bootstrap gui/$(id -u) $SESSION_PLIST"
assert_match "$INST_OUT" 'for this session only'

it 'and restart starts that session-only agent again'
: >"$TK_FAKE_LAUNCHCTL"
set +e; RST_OUT=$("$MAC_DIR/trigger-kvm" restart </dev/null 2>&1); RST_RC=$?; set -e
assert_equal 0 "$RST_RC" "$RST_OUT"
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" "bootstrap gui/$(id -u) $SESSION_PLIST"
rm -f "$SESSION_PLIST"

# =============================================================================
# launchd is allowed to refuse, and a refusal must explain itself
# =============================================================================
#
# specs/configure.md 4.4: an interrupted run must leave a working setup
# untouched, and where it cannot, it has to say what is left. The bootout runs
# BEFORE the bootstrap, so between them nothing is watching, and every caller
# runs under `set -euo pipefail`: an unchecked `bootstrap system` would abort
# there with the daemon installed, the agent booted out, and `status` reporting
# "at boot" off the plist on disk.

it 'a refused bootstrap falls back to the login tier and says why'
write_config_with_tier 'install.autostart = boot'
rm -f "$TK_DAEMON_PLIST" "$TK_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
TK_FAKE_LAUNCHCTL_FAIL=bootstrap PATH="$FAKE_DIR/bin:$PATH" run_install
assert_equal 0 "$INST_RC" "the install must not abort mid-window: $INST_OUT"
# The reason is pinned to ITS OWN message: asserting the string anywhere in the
# output passed on the fallback's message instead, which is a different call.
assert_match "$INST_OUT" 'launchd would not load it: Load failed: 5: Input/output error'
assert_match "$INST_OUT" 'falling back to starting at login'

it 'and leaves NO daemon plist, so status cannot go on claiming "at boot"'
# tk_installed_tier reads the file's existence, not launchd. A plist left after
# a refused load is exactly how `status` comes to promise coverage from boot
# with nothing running at all.
assert_true "$([ ! -f "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" \
  "a daemon launchd refused must not be left on disk: $INST_OUT"

it 'and rewrites the config to the tier that actually happened'
assert_match "$(cat "$SUPPORT/config")" 'install.autostart = login' \
  'the config records what happened, not what was asked for'

it 'and never reports the boot tier as installed'
assert_no_match "$INST_OUT" 'installed the boot-time start'
assert_no_match "$INST_OUT" 'before anyone logs in'

it 'a fallback whose login tier cannot be written leaves the config alone'
# specs/configure.md 8: record the fallback only once it has taken effect. The
# rewrite used to sit in the boot-failure branch, one step early, so this run
# left `login` in the config with the daemon removed and no agent written --
# `status` then promised a tier that did not exist, and the next configure read
# `login` and demoted the boot choice the user had made.
write_config_with_tier 'install.autostart = boot'
rm -f "$TK_DAEMON_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
# The agent plist cannot be written: its parent is a regular file.
printf 'not a directory\n' >"$FAKE_DIR/blocker"
TK_PLIST="$FAKE_DIR/blocker/fake-LaunchAgents.plist" TK_FAKE_LAUNCHCTL_FAIL=bootstrap \
  PATH="$FAKE_DIR/bin:$PATH" run_install
assert_match "$INST_OUT" 'the generated LaunchAgent is malformed; not loading it'
assert_match "$(cat "$SUPPORT/config")" 'install.autostart = boot' \
  'nothing was installed, so the config may not record a downgrade'
assert_true "$([ ! -f "$FAKE_DIR/blocker/fake-LaunchAgents.plist" ] && echo 0 || echo 1)" \
  'no agent plist was written'

it 'a refused LaunchAgent load is reported with the reason, and is not fatal'
# Over SSH there is no gui domain to load into, which is normal and must not
# fail the install -- but it may not be silent either.
write_config_with_tier 'install.autostart = login'
rm -f "$TK_DAEMON_PLIST" "$TK_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
TK_FAKE_LAUNCHCTL_FAIL=bootstrap run_install
assert_equal 0 "$INST_RC" "$INST_OUT"
assert_match "$INST_OUT" 'could not load the LaunchAgent now: Load failed: 5: Input/output error'
assert_match "$INST_OUT" 'starts at your next login'
assert_no_match "$INST_OUT" 'loaded the LaunchAgent'
assert_true "$([ -f "$TK_PLIST" ] && echo 0 || echo 1)" 'the agent is still written for next login'

# =============================================================================
# restart says whether anything is actually watching
# =============================================================================

TK="$MAC_DIR/trigger-kvm"
RST_OUT=""; RST_RC=0
run_restart() {
  set +e
  RST_OUT=$("$TK" restart </dev/null 2>&1)
  RST_RC=$?
  set -e
}

it 'restart reports a refused LaunchAgent load instead of claiming success'
# The login branch verified with tk_agent_loaded; the BOOT branch below did not,
# and said "restarted" whatever happened.
rm -f "$TK_DAEMON_PLIST"
: >"$TK_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
TK_FAKE_LAUNCHCTL_FAIL=bootstrap run_restart
assert_equal 1 "$RST_RC" "$RST_OUT"
assert_match "$RST_OUT" 'could not load the LaunchAgent: Load failed: 5: Input/output error'
assert_match "$RST_OUT" 'NOTHING IS WATCHING'
assert_no_match "$RST_OUT" 'has re-read the config'

it 'restart reports a refused boot-time load instead of claiming success'
: >"$TK_DAEMON_PLIST"
: >"$TK_FAKE_LAUNCHCTL"
TK_FAKE_LAUNCHCTL_FAIL=bootstrap PATH="$FAKE_DIR/bin:$PATH" run_restart
assert_equal 1 "$RST_RC" "$RST_OUT"
assert_match "$RST_OUT" 'could not start the boot-time watcher: Load failed: 5: Input/output error'
assert_match "$RST_OUT" 'NOTHING IS WATCHING'
assert_no_match "$RST_OUT" 'has re-read the config'

it 'and says so when it worked'
: >"$TK_FAKE_LAUNCHCTL"
PATH="$FAKE_DIR/bin:$PATH" run_restart
assert_equal 0 "$RST_RC" "$RST_OUT"
assert_match "$RST_OUT" 'restarted; the watcher has re-read the config.'

# Put back what this section found: a boot-tier config with its daemon plist in
# place. The cases below run in sequence against it, and the uninstall at the
# end asserts that BOTH tiers are torn down.
write_config_with_tier 'install.autostart = boot'
: >"$TK_DAEMON_PLIST"

it 'removes an install from before the rename, so two watchers cannot both fire'
# The old LaunchAgent (com.chrisrishel.displayswitch) ran a watcher called
# usb-watch. Nothing removed it, and one was found a day after the rename still
# firing its own switcher on every flip beside the new one.
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.local/bin"
: >"$HOME/Library/LaunchAgents/com.chrisrishel.displayswitch.plist"
: >"$HOME/.local/bin/usb-watch"
: >"$HOME/.local/bin/switch-displays.sh"
: >"$TK_FAKE_LAUNCHCTL"
PATH="$FAKE_DIR/bin:$PATH" run_install
assert_equal 0 "$INST_RC" "$INST_OUT"
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootout gui/'
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'com.chrisrishel.displayswitch'
assert_true "$([ ! -e "$HOME/Library/LaunchAgents/com.chrisrishel.displayswitch.plist" ] && echo 0 || echo 1)" 'old plist removed'
assert_true "$([ ! -e "$HOME/.local/bin/usb-watch" ] && echo 0 || echo 1)" 'old watcher removed'
assert_true "$([ ! -e "$HOME/.local/bin/switch-displays.sh" ] && echo 0 || echo 1)" 'old switcher removed'
assert_match "$INST_OUT" 'removed the pre-rename'

it 'uninstall removes the program, the launcher and both tiers, and keeps the config and log'
: >"$TK_FAKE_LAUNCHCTL"
PATH="$FAKE_DIR/bin:$PATH" run_install uninstall
assert_equal 0 "$INST_RC" "$INST_OUT"
assert_true "$([ ! -e "$HOME/.local/share/trigger-kvm" ] && echo 0 || echo 1)" 'program directory removed'
assert_true "$([ ! -e "$HOME/.local/bin/trigger-kvm" ] && echo 0 || echo 1)" 'launcher removed'
assert_true "$([ ! -e "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" 'daemon plist removed'
assert_true "$([ ! -e "$TK_PLIST" ] && echo 0 || echo 1)" 'agent plist removed'
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootout system/'
assert_true "$([ -f "$SUPPORT/config" ] && echo 0 || echo 1)" 'the config is kept'
assert_match "$INST_OUT" 'config and log kept'

# =============================================================================
# the launcher refuses a bad config by name (specs/detector.md 4)
# =============================================================================

it 'watch refuses a trigger.device entry it cannot parse, naming it'
CFGW=$(printf '%s' "$CONFIG_THIS_DESK" | sed 's|^trigger.device.*|trigger.device = usb:046d:0843, hid:1:2|' | make_config)
run_tk watch --config "$CFGW"
assert_equal 2 "$TK_RC" "$TK_OUT"
assert_match "$TK_OUT" 'REFUSING to watch'
assert_match "$TK_OUT" 'hid:1:2'

it 'watch refuses a debounce that is not seconds, rather than passing zero on'
CFGW=$(printf '%s' "$CONFIG_THIS_DESK" | sed 's|^trigger.debounce.*|trigger.debounce = three|' | make_config)
run_tk watch --config "$CFGW"
assert_equal 2 "$TK_RC" "$TK_OUT"
assert_match "$TK_OUT" "trigger.debounce = 'three' is not a number of seconds"

it 'and starts the watcher when the config is sound'
CFGW=$(printf '%s' "$CONFIG_THIS_DESK" | make_config)
run_tk watch --config "$CFGW"
assert_equal 0 "$TK_RC" "$TK_OUT"

# =============================================================================
# the bare command
# =============================================================================

it 'a bare trigger-kvm prints usage and moves nothing'
# The first thing a stranger types to see what a command does is the bare
# command; a default of `pull` would re-assert both monitors.
CFG=$(printf '%s' "$CONFIG_THIS_DESK" | make_config)
fake_displays "$FAKE_LG" "$FAKE_ASUS"
fake_reset
set +e; TK_OUT=$("$TK" 2>&1); TK_RC=$?; set -e
assert_equal 2 "$TK_RC" "$TK_OUT"
assert_match "$TK_OUT" 'usage: trigger-kvm <verb>'
assert_nothing_sent 'a bare command must never reach the transport'

it 'configure refuses to run as root before asking anything'
PATH="$FAKE_DIR/asroot:$PATH" run_tk configure --config "$CFG" </dev/null
assert_equal 2 "$TK_RC" "$TK_OUT"
assert_match "$TK_OUT" 'not with sudo'
assert_no_match "$TK_OUT" '--- configuration ---'

finish
