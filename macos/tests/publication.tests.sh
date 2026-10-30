#!/bin/bash
# Publication regressions. All device, launchd and elevation operations use
# fixtures; the compiled watcher callback is exercised without a run loop.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fake_setup
export HOME="$FAKE_DIR/home"
mkdir -p "$HOME"
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/config.sh"
. "$MAC_DIR/lib/menu.sh"
. "$MAC_DIR/lib/answers.sh"
. "$MAC_DIR/lib/walkthrough.sh"
. "$MAC_DIR/lib/manage.sh"
. "$MAC_DIR/lib/checks.sh"

it 'an arrival that resolves ambiguity establishes a baseline without firing'
cat >"$FAKE_DIR/arrival.c" <<'EOS'
#define main watcher_main
#include "event-watch.c"
#undef main
int main(void) {
    add_device("usb:046d:c547@receiver@aaaa");
    watch_t *w = &g_watch[0];
    w->primed = true;
    w->ambiguous = true;
    usb_set_t arrived = {0};
    usb_dev_t d = {0};
    d.vendor = 0x046d; d.product = 0xc547;
    strcpy(d.name, "Receiver"); strcpy(d.where, "aaaa");
    usb_set_add(&arrived, &d);
    usb_arrived(w, &arrived);
    return g_settle_pending || w->arrived;
}
EOS
clang -O0 -Wall -Wextra -I "$MAC_DIR" "$FAKE_DIR/arrival.c" \
  -framework IOKit -framework CoreFoundation -o "$FAKE_DIR/arrival"
USB="$FAKE_DIR/usb"
printf '%s\n' '046d|c547|Receiver|bbbb|' '046d|c547|Receiver|cccc|' \
  '046d|c547|Receiver|aaaa|' >"$USB"
rc=0
TK_USB_LIST="$USB" "$FAKE_DIR/arrival" >/dev/null 2>&1 || rc=$?
assert_equal 0 "$rc" 'resolving ambiguity must not schedule a pull'

it 'the one-shot does not report an arrival when one ambiguous twin is removed'
printf '%s\n' '046d|c547|Receiver|bbbb|' '046d|c547|Receiver|cccc|' >"$USB"
( sleep 0.9; printf '%s\n' '046d|c547|Receiver|bbbb|' >"$USB.next"; mv "$USB.next" "$USB" ) &
writer=$!
rc=0
out=$(TK_USB_LIST="$USB" "$MAC_DIR/event-watch" --test-trigger \
  --device usb:046d:c547@receiver --timeout 3 2>&1) || rc=$?
wait "$writer"
assert_equal 1 "$rc" "$out"
assert_no_match "$out" 'arrived --' 'a removal cannot pass a trigger check'

it 'Escape rolls back names and maps while Done commits them'
for end in -1 5; do
  out=$(
    WT_THIS=mac; WT_COMPUTERS=(mac pc)
    WT_A=("$(wt_record 06B3:42E0 main Monitor standard 0x06B3 0x42E0 'mac=0x0F,pc=0x11' 0)")
    picks="1 $end"
    select_one() { MENU_PICK=${picks%% *}; picks=${picks#* }; }
    wt_read_name() { printf 'renamed\n'; }
    wt_computers >/dev/null 2>&1
    wt_rec 0
    printf '%s|%s' "${WT_COMPUTERS[*]}" "$R_MAP"
  )
  if [ "$end" = -1 ]; then assert_equal 'mac pc|mac=0x0F,pc=0x11' "$out"
  else assert_equal 'mac renamed|mac=0x0F,renamed=0x11' "$out"; fi
done

it 'Escape rolls back removals and monitor edits within their submenus'
for submenu in remove monitors; do
  out=$(
    WT_THIS=mac; WT_COMPUTERS=(mac pc laptop)
    WT_A=("$(wt_record 06B3:42E0 main Monitor standard 0x06B3 0x42E0 'mac=0x0F,pc=0x11,laptop=0x12' 0)")
    picks='0 -1'
    select_one() { MENU_PICK=${picks%% *}; picks=${picks#* }; }
    read_yesno() { return 0; }
    if [ "$submenu" = remove ]; then
      wt_remove_computer pc laptop >/dev/null 2>&1
      printf '%s|' "${WT_REMAINING[*]}"
    else
      WT_F=("$(wt_record 06B3:42E0 0x06B3 0x42E0 AUS Monitor 1)")
      wt_display_answers() {
        wt_record 06B3:42E0 main Monitor standard 0x06B3 0x42E0 'mac=0x11' 0
      }
      wt_monitors >/dev/null 2>&1
    fi
    wt_rec 0
    printf '%s' "$R_MAP"
  )
  if [ "$submenu" = remove ]; then
    assert_equal 'pc laptop|mac=0x0F,pc=0x11,laptop=0x12' "$out"
  else
    assert_equal 'mac=0x0F,pc=0x11,laptop=0x12' "$out"
  fi
done

it 'EOF during trigger confirmation restores the paused watcher'
: >"$TK_FAKE_LAUNCHCTL"
rc=0
(
  trap - EXIT
  WT_DEVICES=(usb:dead:beef); TK_SELF=/usr/bin/true
  wt_pull_allowed() { return 0; }
  tk_installed_tier() { printf 'login\n'; }
  tk_agent_loaded() { return 0; }
  tk_agent_plist() { printf '%s\n' "$TK_PLIST"; }
  wt_write_config() { :; }
  wt_check_triggers </dev/null
) >"$FAKE_DIR/eof.out" 2>&1 || rc=$?
assert_equal 2 "$rc" 'EOF must still abort the walkthrough'
assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap gui/' 'restore even on shell exit'

it 'trigger cleanup restores only the watcher this check successfully paused'
for mode in signal config-failure timeout already-paused pause-refused; do
  : >"$TK_FAKE_LAUNCHCTL"
  rc=0
  (
    trap - EXIT
    WT_DEVICES=(usb:dead:beef); TK_SELF=/usr/bin/true
    wt_pull_allowed() { return 1; }
    tk_installed_tier() { printf 'login\n'; }
    tk_agent_loaded() { [ "$mode" != already-paused ]; }
    tk_agent_plist() { printf '%s\n' "$TK_PLIST"; }
    wt_write_config() {
      printf '%s\n' "$1" >"$FAKE_DIR/check-temp"
      case $mode in
        signal) /bin/sh -c 'kill -TERM "$PPID"' ;;
        config-failure) return 7 ;;
      esac
      return 0
    }
    [ "$mode" != timeout ] || export TK_FAKE_TRIGGER_RC=1
    [ "$mode" != pause-refused ] || export TK_FAKE_LAUNCHCTL_FAIL=bootout
    wt_check_triggers
  ) >"$FAKE_DIR/cleanup.out" 2>&1 || rc=$?
  case $mode in
    signal) assert_equal 130 "$rc" "$(cat "$FAKE_DIR/cleanup.out")" ;;
    config-failure) assert_equal 7 "$rc" ;;
    *) assert_equal 0 "$rc" "$(cat "$FAKE_DIR/cleanup.out")" ;;
  esac
  case $mode in
    already-paused|pause-refused)
      assert_no_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap' "$mode must not start a watcher" ;;
    *) assert_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap gui/' "$mode must restore the paused watcher" ;;
  esac
  assert_true "$([ ! -f "$(cat "$FAKE_DIR/check-temp")" ] && echo 0 || echo 1)" 'remove temporary config'
done

it 'a failed bootout prevents replacement of an installed boot tier'
fake_sudo_stub
CFG="$FAKE_DIR/config"
printf 'install.autostart = no\n' >"$CFG"
: >"$TK_DAEMON_PLIST"; : >"$TK_FAKE_LAUNCHCTL"
rc=0
out=$(TK_FAKE_LAUNCHCTL_FAIL=bootout PATH="$FAKE_DIR/bin:$PATH" \
  tk_apply_tier "$CFG" 2>&1) || rc=$?
assert_equal 1 "$rc" "$out"
assert_true "$([ -f "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" 'retain the boot plist on refusal'
assert_no_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap gui/' 'do not install a competing tier'

it 'a failed plist removal also prevents installation of a replacement tier'
cat >"$FAKE_DIR/bin/rm" <<'EOS'
#!/bin/sh
for arg do
  [ "$arg" != "$TK_DAEMON_PLIST" ] || exit 1
done
exec /bin/rm "$@"
EOS
chmod +x "$FAKE_DIR/bin/rm"
: >"$TK_FAKE_LAUNCHCTL"
rc=0
out=$(PATH="$FAKE_DIR/bin:$PATH" tk_apply_tier "$CFG" 2>&1) || rc=$?
assert_equal 1 "$rc" "$out"
assert_no_match "$(cat "$TK_FAKE_LAUNCHCTL")" 'bootstrap gui/'
assert_true "$([ -f "$TK_DAEMON_PLIST" ] && echo 0 || echo 1)" 'failed removal retains boot registration'

finish
