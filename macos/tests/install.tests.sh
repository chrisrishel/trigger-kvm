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
# It used to warn and carry on, leaving a full install that could only refuse
# to switch -- discovered at the first monitor check rather than the first line.
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
# The tier used to be read with a private sed that kept the comment and was
# case-sensitive. The spec's own example line -- `install.autostart = boot   #
# boot | login | no` -- read as neither tier, so an upgrade REMOVED the boot
# daemon while the config still said boot.
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
# the bare command
# =============================================================================

it 'a bare trigger-kvm prints usage and moves nothing'
# It used to default to `pull`. The first thing a stranger types to see what a
# command does is the bare command, and that re-asserted both monitors.
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
