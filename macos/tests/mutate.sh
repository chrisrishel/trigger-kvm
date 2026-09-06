#!/bin/bash
# shellcheck disable=SC2016  # every string below is a sed expression: $ and \ are
#                              sed's, not the shell's, and must not expand here
#
# Mutation check: a passing test proves nothing until it can fail.
#
#   ./mutate.sh              every mutation
#   ./mutate.sh switch       only mutations whose name matches
#
# Each entry reintroduces a bug the suite is supposed to catch -- most of them
# bugs this project has actually shipped -- and asserts that some test goes red.
# A SURVIVING mutation is a failure of this script: it means an assertion is
# passing for a reason other than the one it claims.
#
# A mutation is only judged against a suite file that PASSES UNMUTATED. Each
# suite is run once, clean, before its first mutation; if it is red already,
# every mutation aimed at it is reported UNJUDGED and counted as survived,
# because "the suite went red" then proves nothing. Before this, a suite that
# was red for an unrelated reason made every mutation aimed at it read as
# caught -- eight of them, for a whole day.
#
# This is not run by run.sh. It edits files in place, so it is a thing you run
# deliberately, and it restores every file it touches even when a test wedges.
# Ctrl-C (INT), TERM and HUP restore the file in flight, rebuild, and STOP.

set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
MAC_DIR=$(dirname "$HERE")
FILTER=${1:-}
[ "$FILTER" = "--restore-only" ] && FILTER="__none__"

survived=0
checked=0
unjudged=0

# One clean run per suite file, remembered as a marker file (bash 3.2 has no
# associative arrays). "ok" or "red".
BASE_DIR=$(mktemp -d -t trigger-kvm-mutate)
trap 'rm -rf "$BASE_DIR"' EXIT

# Run a suite file with the same watchdog a mutation gets; 0 = passed.
run_suite() {
  bash "$HERE/$1" >/tmp/tk-mutate.out 2>&1 & p=$!
  ( sleep "${TK_MUTATE_TIMEOUT:-300}"; kill -9 $p 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  # Disowned so bash does not print "Terminated: 15" over the verdicts when the
  # watchdog is killed after the suite returns on its own.
  disown $w 2>/dev/null || true
  wait $p; rc=$?; kill $w 2>/dev/null
  return $rc
}

# Is this suite green on the UNMUTATED tree? Measured once, then remembered.
suite_is_green() {
  if [ ! -f "$BASE_DIR/$1" ]; then
    if run_suite "$1"; then echo ok >"$BASE_DIR/$1"; else echo red >"$BASE_DIR/$1"; fi
  fi
  [ "$(cat "$BASE_DIR/$1")" = "ok" ]
}

# A run that is killed outright (SIGKILL, a watchdog, a closed terminal) cannot
# run its trap, and would leave a MUTATED source and a mutated binary behind --
# which then silently becomes what the next test run measures. That happened
# once and cost an hour chasing a lock bug that did not exist. So: restore
# anything left over before doing anything else, and say so.
for bak in "$MAC_DIR"/*.mutbak "$MAC_DIR"/lib/*.mutbak "$MAC_DIR"/tests/*.mutbak \
           "$MAC_DIR"/../specs/*.mutbak; do
  [ -f "$bak" ] || continue
  echo "  restoring ${bak%.mutbak} left mutated by an interrupted run"
  mv -f "$bak" "${bak%.mutbak}"
done
make -B -C "$MAC_DIR" -s >/dev/null 2>&1 || true

# mutate <name> <file> <suite> <sed-expression>
#
# A .c target is rebuilt after the edit and rebuilt again from the restored
# source afterwards, so a mutation run never leaves a mutated binary behind for
# the next test -- or for the developer.
mutate() {
  name=$1; file=$2; suite=$3; expr=$4
  case $name in *"$FILTER"*) ;; *) return 0 ;; esac

  target="$MAC_DIR/$file"

  if ! suite_is_green "$suite"; then
    echo "  UNJUDGED  $name  ->  $suite is red before any mutation; fix the suite first"
    checked=$(( checked + 1 )); survived=$(( survived + 1 )); unjudged=$(( unjudged + 1 ))
    return 0
  fi

  cp "$target" "$target.mutbak"
  # A signal must not leave the mutant in place -- and it must STOP the run. A
  # handler that restores and returns lets the script carry on to the next
  # mutation, which is what this did until it was measured: a TERM produced a
  # restore, a spurious verdict and forty more mutations.
  # shellcheck disable=SC2064
  trap "mv -f '$target.mutbak' '$target' 2>/dev/null; make -B -C '$MAC_DIR' -s >/dev/null 2>&1; rm -rf '$BASE_DIR'" EXIT
  # shellcheck disable=SC2064
  trap "kill \$p 2>/dev/null; mv -f '$target.mutbak' '$target' 2>/dev/null; make -B -C '$MAC_DIR' -s >/dev/null 2>&1; rm -rf '$BASE_DIR'; echo '  interrupted -- source restored'; exit 130" INT TERM HUP

  sed -i '' "$expr" "$target"
  if cmp -s "$target" "$target.mutbak"; then
    echo "  ERROR  mutation did not apply: $name"
    checked=$(( checked + 1 )); survived=$(( survived + 1 ))
  elif case $file in
         *.c) ! make -B -C "$MAC_DIR" -s >/dev/null 2>&1 ;;
         *)   ! bash -n "$target" 2>/dev/null ;;
       esac; then
    # A mutant that does not build or does not parse tests nothing: the suite
    # goes red for the wrong reason and the mutation reads as caught.
    echo "  ERROR  mutated source does not build: $name"
    checked=$(( checked + 1 )); survived=$(( survived + 1 ))
  else
    checked=$(( checked + 1 ))
    # A mutant can HANG rather than fail -- one sat on a single configure for 28
    # minutes because a prompt at EOF re-asked forever. Bound it, the same way
    # run.sh bounds a test file.
    if run_suite "$suite"; then
      echo "  SURVIVED  $name"
      survived=$(( survived + 1 ))
    else
      echo "  caught    $name  ->  $(grep -m1 'FAIL' /tmp/tk-mutate.out | sed 's/^ *FAIL *//')"
    fi
  fi

  mv -f "$target.mutbak" "$target"
  case $file in *.c) make -B -C "$MAC_DIR" -s >/dev/null 2>&1 || true ;; esac
  trap - INT TERM HUP
  trap 'rm -rf "$BASE_DIR"' EXIT
}

# --- the config reader -------------------------------------------------------

mutate 'config: value not cut at #' lib/config.sh config.tests.sh \
  's|sub(/#\.\*\$/, "", line)|# mutated|'
mutate 'config: keys not lower-cased' lib/config.sh config.tests.sh \
  's|print tolower(key)|print key|'
mutate 'config: byte parser defaults to 0 instead of failing' lib/config.sh config.tests.sh \
  's|^  return 1$|  printf "0\\n"; return 0|'
mutate 'config: leading zero read as octal' lib/config.sh config.tests.sh \
  's|10#\$1|$1|g'
mutate 'config: no AMBIGUOUS detection' lib/config.sh config.tests.sh \
  's|seen\[\$1\] = "AMBIGUOUS"|seen[$1] = seen[$1]|'
mutate 'config: value not trimmed' lib/config.sh config.tests.sh \
  's|gsub(/\^\[ .t\]+/, "", val); ||'
mutate 'config: first duplicate key wins instead of the last' lib/config.sh config.tests.sh \
  's|{ v = substr($0, length($1) + 2) }|{ if (!f) { v = substr($0, length($1) + 2); f = 1 } }|'

# --- the switcher ------------------------------------------------------------

mutate 'switch: LG service channel sent to any vendor' lib/display.sh switch.tests.sh \
  's|if \[ "\$_vendor" != "\$DDC_VENDOR_GSM" \]; then|if false; then|'
mutate 'switch: method coerced to standard, ignoring the config' lib/display.sh switch.tests.sh \
  's|_method=\$(tk_lower "\$(config_display_field "\$_label" method standard)")|_method=standard|'
mutate 'switch: resolve takes the first of several matches' lib/display.sh switch.tests.sh \
  's|if \[ "\$_n" = "1" \]; then|if [ "$_n" != "0" ]; then _match=$(printf "%s\\n" "$_match" \| head -1);|'
mutate 'switch: checksum omits the 0x6E seed' lib/display.sh switch.tests.sh \
  's|_sum=\$(( 0x6E \^ _src|_sum=$(( 0x00 ^ _src|'
mutate 'switch: standard method uses the LG VCP' lib/display.sh switch.tests.sh \
  's|ddc_packet "\$DDC_SOURCE_STANDARD" "\$DDC_VCP_STANDARD"|ddc_packet "$DDC_SOURCE_STANDARD" "$DDC_VCP_LG"|'
mutate 'switch: log lines go to stdout and swallow the refusal' lib/common.sh switch.tests.sh \
  's|"\$_line" >&2|"$_line"|'
mutate 'switch: a dry run sends anyway' lib/display.sh switch.tests.sh \
  's|if \[ "\$_dry" = "1" \]; then|if false; then|'
mutate 'switch: writes sent once, not twice' lib/display.sh switch.tests.sh \
  's|TK_TRIES=\${TK_TRIES:-2}|TK_TRIES=${TK_TRIES:-1}|'

# --- resolve-before-send -----------------------------------------------------
#
# The one AGENTS.md hard rule 5 asks to be asserted as a property: not that a
# check ran, but that NOTHING WAS SENT. This mutation is the Windows bug --
# carry on past an unresolvable value and let it reach the wire.

mutate 'switch: unresolvable value moves the panels it CAN resolve' trigger-kvm switch.tests.sh \
  's|        tk_log "REFUSING: .\$_l. has no input named|        continue \# |'

# --- the watcher -------------------------------------------------------------

mutate 'watch: no single-instance lock' event-watch.c watcher.tests.sh \
  's@} else if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) {@} else if (false) {@'
mutate 'watch: rotates the log BEFORE taking the lock' event-watch.c watcher.tests.sh \
  '/another watcher is already running/{n;s@return 0;@@;}'
mutate 'watch: fires for a device already present at startup' event-watch.c watcher.tests.sh \
  's|    if (!w->primed) {|    if (false) {|'
mutate 'watch: one-shot runs the exec' event-watch.c watcher.tests.sh \
  's@    if (g_testmode) {@    if (g_testmode) { run_exec();@'
mutate 'watch: one-shot rotates the log' event-watch.c watcher.tests.sh \
  's@    if (g_testmode) {@    if (g_testmode) { if (g_log[0]) rotate_log();@'
mutate 'watch: candidate list filters Bluetooth to connected only' event-watch.c watcher.tests.sh \
  's|        bt_each(items, CFSTR("device_not_connected"), false, bt_row, NULL);||'
mutate 'watch: candidate list keeps hubs' event-watch.c watcher.tests.sh \
  's@            if (strcasestr(name, "hub")@            if (false@'
mutate 'watch: rotates by RENAME, breaking launchd open descriptor' event-watch.c watcher.tests.sh \
  's@    int live = open(g_log, O_WRONLY);@    rename(g_log, old); int live = open(g_log, O_WRONLY | O_CREAT, 0644);@'

# --- the menus ---------------------------------------------------------------

mutate 'menu: cursor does not skip separators and disabled rows' lib/menu.sh menu.tests.sh \
  's@    if \[ -n "${MENU_ITEMS\[$_i\]}" \] && ! menu_is_disabled "$_i"; then _sel+=("$_i"); fi@    _sel+=("$_i")@'
mutate 'menu: (current) is never drawn' lib/menu.sh menu.tests.sh \
  's@  if \[ "$_i" = "$_current" \]; then@  if false; then@'
mutate 'menu: esc is honoured even when the menu is not escapable' lib/menu.sh menu.tests.sh \
  's@        if \[ "$_escapable" = "1" \]; then printf .\\n. >&2; MENU_PICK=-1; return 0; fi@        printf "\\n" >\&2; MENU_PICK=-1; return 0@'
mutate 'menu: detail is truncated instead of wrapped' lib/menu.sh menu.tests.sh \
  's@          sub(/\[ .t\]+\$/, "", line); print line; line = ""@          sub(/[ \t]+$/, "", line); print substr(line, 1, w - 3) "..."; line = ""; break@'
mutate 'menu: item column fixed at 28, never widened' lib/menu.sh menu.tests.sh \
  's@    \[ "$_l" -gt "$_iw" \] && _iw=$_l@    :@'
mutate 'menu: enter on a row ACCEPTS instead of toggling' lib/menu.sh menu.tests.sh \
  '/^      Enter)$/{n;n;n;s%.*%          :%;}'
mutate 'menu: Done accepts an empty selection' lib/menu.sh menu.tests.sh \
  's@        if \[ -n "$_out" \]; then@        if true; then@'
mutate 'menu: typed fallback accepts a disabled row' lib/menu.sh menu.tests.sh \
  '/for _s in "${_sel\[@\]}"; do$/s%.*%        for _s in $(seq 0 $(( ${#MENU_ITEMS[@]} - 1 ))); do%'

# --- the real key reader (pty-driven) ----------------------------------------

mutate 'keys: Enter matches only newline, not a terminal carriage return' lib/menu.sh keys.tests.sh \
  's%13|10)%10)%'
mutate 'keys: any escape byte is Esc, with no continuation read' lib/menu.sh keys.tests.sh \
  's%  if \[ "$_b" = "27" \]; then%  if false; then%'
mutate 'keys: terminal state is never restored' lib/menu.sh keys.tests.sh \
  's%\[ -n "$_saved" \] && stty "$_saved" </dev/tty 2>/dev/null%:%g'

# --- the walkthrough ---------------------------------------------------------

mutate 'walkthrough: Save writes even with a section unset' lib/walkthrough.sh walkthrough.tests.sh \
  's%      if \[ -z "$_missing" \]; then break; fi%      break%'
mutate 'walkthrough: --fresh pre-fills from the existing config anyway' lib/walkthrough.sh walkthrough.tests.sh \
  's%  if \[ "$_fresh" = "1" \]; then%  if false; then%'
mutate 'walkthrough: panels are given a dialect by vendor instead of standard' lib/walkthrough.sh walkthrough.tests.sh \
  's%    _method=standard%    _method=lg-alt%'
mutate 'walkthrough: the PATH row is hidden when it is already on PATH' lib/walkthrough.sh walkthrough.tests.sh \
  's%    \[ "$WT_ONPATH" = "1" \] && menu_disable "$_pathrow"%    :%'
mutate 'walkthrough: Cancel writes the config anyway' lib/walkthrough.sh walkthrough.tests.sh \
  '/cancelled; nothing was changed/{n;s%.*%      break%;}'
mutate 'walkthrough: the input map is written under a key nothing reads' lib/walkthrough.sh walkthrough.tests.sh \
  's@input\.%s@inputs.%s@'

# Enter never destroys (specs/configure.md 5.0, 5.3, 6). Each of these turns a
# confirmation back into the one-keypress loss it replaced.
mutate 'walkthrough: the rename prompt is not pre-filled, so enter is refused' lib/walkthrough.sh walkthrough.tests.sh \
  's%wt_read_name "New name for '"'"'$_victim'"'"'" "$_victim"%wt_read_name "New name for '"'"'$_victim'"'"'" ""%'
mutate 'walkthrough: removing a computer defaults to yes' lib/walkthrough.sh walkthrough.tests.sh \
  's%read_yesno "  Remove '"'"'$_victim'"'"'?" n%read_yesno "  Remove '"'"'$_victim'"'"'?" y%'
mutate 'walkthrough: removing a computer leaves its input in every map' lib/walkthrough.sh walkthrough.tests.sh \
  's%    wt_maps_edit map_del "$_victim"%    :%'
mutate 'walkthrough: unmanaging a monitor never confirms' lib/walkthrough.sh walkthrough.tests.sh \
  's%    if \[ "$(map_count "$_prior")" -gt 0 \]; then%    if false; then%'
mutate 'walkthrough: unmanaging a monitor always confirms, even with nothing to lose' lib/walkthrough.sh walkthrough.tests.sh \
  's%    if \[ "$(map_count "$_prior")" -gt 0 \]; then%    if true; then%'
mutate 'walkthrough: stop-managing defaults to yes' lib/walkthrough.sh walkthrough.tests.sh \
  "s%'  Stop managing this monitor?' n%'  Stop managing this monitor?' y%"
mutate 'walkthrough: declining to stop managing forgets the inputs anyway' lib/walkthrough.sh walkthrough.tests.sh \
  's%    \[ "$_row" = "KEEP" \] && continue%    :%'

# --- the checks --------------------------------------------------------------

mutate 'checks: every panel moves at once, keeping none here' lib/checks.sh checks.tests.sh \
  's%    if \[ "$_np" -eq "$_nscoped" \] && \[ "$_np" -gt 1 \]; then%    if false; then%'
mutate 'checks: the single-monitor recovery text is not shown' lib/checks.sh checks.tests.sh \
  's%    printf ..n  READ THIS FIRST -- this is your only monitor..n. >&2%    :%'
mutate 'checks: declining the single-monitor warning reads as a pass' lib/checks.sh checks.tests.sh \
  's%      WT_ROUND_SKIPPED=1%      WT_ROUND_SKIPPED=0%'
mutate 'checks: the trigger check pulls before the inputs are verified' lib/checks.sh checks.tests.sh \
  's%  \[ "$WT_DISPLAYS_OK" = "1" \] && _pull=1%  _pull=1%'
mutate 'checks: a manufacturer dialect is applied without being offered' lib/checks.sh checks.tests.sh \
  's%    if \[ "$MENU_PICK" = "0" \]; then%    if true; then%'
mutate 'checks: failures are joined on spaces, splitting panel names' lib/checks.sh checks.tests.sh \
  's%^\$_f"%^ $_f"%'

# --- shell scoping -----------------------------------------------------------
#
# Shell variables are global unless declared local, so a callee's loop index
# silently overwrites its caller's. select_many's `_i` did exactly that to
# wt_check_round's, and the check crashed on an unbound array subscript the
# moment a batch was narrowed.

# The defence is the CALLER declaring its own locals -- with dynamic scoping a
# callee then writes to its own copy. So the mutation to make is removing the
# locals from the function whose state was corrupted, not from the menu that
# corrupted it.
mutate 'scope: a function stops declaring its scratch local' lib/checks.sh conventions.tests.sh \
  '/^wt_check_round() {/{n;s%^  local .*%  :%;}'
mutate 'scope: a menu stops declaring its scratch local' lib/menu.sh conventions.tests.sh \
  '/^select_many_body() {/{n;s%^  local .*%  :%;}'
mutate 'sidechannel: input-alt appears somewhere else too' lib/display.sh conventions.tests.sh \
  's%^# --- the packet%_unused_alt="input-alt"\n# --- the packet%'

# --- spec conformance --------------------------------------------------------
#
# The check is what makes "change the spec first" a rule rather than a hope, so
# it has to be able to fail. Drop a normative string from the implementation and
# the suite must go red.

mutate 'spec: an implementation renames a section header' lib/walkthrough.sh spec.tests.sh \
  's%--- computers ---%--- machines ---%'
mutate 'spec: an implementation drops a normative sentence' lib/walkthrough.sh spec.tests.sh \
  's%These monitors are shared between this computer%These monitors are shared between this box%'
mutate 'spec: the checker stops reporting anything missing' ../specs/check-conformance.sh spec.tests.sh \
  's%MISSING=$(( MISSING + 1 ))%:%'

# The revision check is what tells a platform it is behind on a spec change the
# conformance check cannot see. It has to be able to fail in both directions.

mutate 'revision: this platform falls behind the changelog' SPEC-REVISION spec.tests.sh \
  's%^revision = [0-9]*%revision = 0%'
mutate 'revision: this platform claims a revision that does not exist' SPEC-REVISION spec.tests.sh \
  's%^revision = [0-9]*%revision = 99%'

# --- revision 7: the detector's contract; the shared reader fixture ---------

mutate 'watch: settle fires when ANY device is present, not the arriving one' event-watch.c watcher.tests.sh \
  's|        if (g_watch\[i\].arrived && now\[i\]) still = true;|        if (now[i]) still = true;|'
mutate 'watch: a loose device grammar accepts usb:46d:843 and trailing junk' event-watch.c watcher.tests.sh \
  's|        if (!usb_spec_ok(s)) return false;|        ;|'
mutate 'watch: a timing that is not a number reads as zero' event-watch.c watcher.tests.sh \
  's|    if (!ok \|\| \*p != .\\0.) {|    if (false) {|'
mutate 'config: an unknown trigger entry is prefixed into a usb: key that matches nothing' lib/config.sh config.tests.sh \
  's|      elif \[\[ \$_d =~ \^\[0-9a-f\]{4}:\[0-9a-f\]{4}\$ \]\];     then printf .usb:%s\\n. "\$_d"|      else printf "usb:%s\\n" "$_d"|'
mutate 'config: a word above 65535 is accepted' lib/config.sh spec.tests.sh \
  's|      \[ \$(( 10#\$1 )) -le 65535 \] \|\| return 1|      :|'
mutate 'watch: the launcher passes a bad trigger entry through' lib/manage.sh install.tests.sh \
  's|^  _bad=\$(config_bad_trigger_devices)$|  _bad=""|'
mutate 'walkthrough: Save drops every key it did not ask about' lib/walkthrough.sh walkthrough.tests.sh \
  's|^    _other=\$(wt_other_keys)$|    _other=""|'
mutate 'spec: the checker measures a fragment before trimming it' ../specs/check-conformance.sh spec.tests.sh \
  's|      t = trim(line)$|      t = line|'
mutate 'spec: the changelog head is the first heading, not the largest' tests/spec.tests.sh spec.tests.sh \
  's/| sort -n | tail -1; }/| head -1; }/'

# --- revision 6: name the consequence; a panel is one submenu ---------------

mutate 'walkthrough: the method chooser does not name the service channel' lib/walkthrough.sh walkthrough.tests.sh \
  's|sent only the values written down for it: unknown values on that|mutated|'
mutate 'walkthrough: a typed value on a manufacturer channel gets no warning' lib/walkthrough.sh walkthrough.tests.sh \
  's|This is the manufacturer.*s service channel. Type only a value you have|mutated|'
mutate 'walkthrough: esc at the method question advances instead of backing out' lib/walkthrough.sh walkthrough.tests.sh \
  's|^    \[ "\$_method" = "BACK" \] && { printf .KEEP.n.; return 0; }$|    :|'
mutate 'walkthrough: esc at an input question is ignored' lib/walkthrough.sh walkthrough.tests.sh \
  's|^    \[ "\$WT_INPUT_ESC" = "1" \] && { printf .KEEP.n.; return 0; }$|    :|'
mutate 'walkthrough: a duplicate short name is accepted' lib/walkthrough.sh walkthrough.tests.sh \
  's|"\$(wt_labels_except "\$_key")" monitor)|"" monitor)|'
mutate 'walkthrough: typed input values are compared by spelling, not by value' lib/walkthrough.sh walkthrough.tests.sh \
  's|^      _v=\$(printf .0x%02X. "\$_n")$|      _v=$_typed|'
mutate 'tier: From boot is offered to an account that cannot elevate' lib/walkthrough.sh walkthrough.tests.sh \
  's|  if wt_is_admin; then|  if true; then|'
mutate 'checks: the trigger check leaves the installed watcher running' lib/checks.sh checks.tests.sh \
  's@^        "\$TK_LAUNCHCTL" bootout "\$(tk_domain)/\$TK_LABEL" >/dev/null 2>&1 || true$@        :@'
mutate 'checks: backing out of the scope question counts as a failed check' lib/checks.sh checks.tests.sh \
  "s|WT_RAN_DISPLAYS='not checked'; WT_DISPLAYS_OK=''; return 0|WT_RAN_DISPLAYS='not checked'; WT_DISPLAYS_OK=0; return 0|"

# --- the tiers own launchd ---------------------------------------------------

mutate 'tier: choosing boot leaves the LaunchAgent behind' lib/manage.sh walkthrough.tests.sh \
  's|^      rm -f "\$TK_PLIST"$|      :|'
mutate 'tier: autostart read with a comment-blind, case-sensitive sed' lib/manage.sh install.tests.sh \
  's@^  TK_TIER_APPLIED=\$(tk_lower "\$(config_get install.autostart)")$@  TK_TIER_APPLIED=$(sed -n "s/^[[:space:]]*install\\.autostart[[:space:]]*=[[:space:]]*//p" "$CONFIG" | tail -1)@'
mutate 'walkthrough: configure ends without saying what to do next' trigger-kvm walkthrough.tests.sh \
  's|tk_apply_tier "\$CONFIG"; tk_say_done; exit 0|tk_apply_tier "$CONFIG"; exit 0|'

mutate 'install: a pre-rename install is left running' install.sh install.tests.sh \
  's|^remove_prerename_install$|:|'
mutate 'config: the CR of a CRLF file rides on every value' lib/config.sh config.tests.sh \
  's|      sub(/\\r\$/, "", line)|      # mutated|'
mutate 'menu: Ctrl-C leaves the terminal in raw mode' lib/menu.sh keys.tests.sh \
  "s|  trap 'menu_tty_restore; exit 130' INT TERM|  :|"

# --- the installer's preflight -----------------------------------------------

mutate 'install: a preflight failure does not stop the install' install.sh install.tests.sh \
  's|^refuse() { say "\$@"; say .Nothing was installed..; exit 1; }|refuse() { say "$@"; }|'
mutate 'install: runs as root without complaint' lib/manage.sh install.tests.sh \
  's|  if \[ "\$(id -u)" -eq 0 \]; then|  if false; then|'
mutate 'switch: a bare trigger-kvm pulls instead of printing usage' trigger-kvm install.tests.sh \
  's|^\[ \$# -gt 0 \] \|\| usage$|[ $# -gt 0 ] \|\| set -- pull|'

mutate 'watch: an oversized Bluetooth entry is clamped after the write, not skipped' event-watch.c watcher.tests.sh \
  's|        if (nk < 1 \|\| nk > 8) continue;|        if (nk < 1) continue; if (nk > 8) nk = 8;|'

# --- a refused bootstrap is caught, never thrown -------------------------------
#
# The bootout runs first, so between the two calls nothing is watching. These
# reintroduce each way that window used to go unreported.

mutate 'bootstrap: the boot-tier load is unchecked, so a refusal aborts mid-window' lib/manage.sh install.tests.sh \
  's@    elif ! tk_bootstrap system "\$TK_DAEMON_PLIST"; then@    elif ! { tk_bootstrap system "$TK_DAEMON_PLIST" || true; }; then@'
# Falling back to login is what clears a daemon launchd refused. If that removal
# goes, `status` reads the plist off disk and promises coverage from boot with
# nothing running -- which is the failure the whole seam exists to prevent.
mutate 'bootstrap: a daemon launchd refused is left on disk for status to report' lib/manage.sh install.tests.sh \
  's@^      sudo rm -f "\$TK_DAEMON_PLIST" || true$@      :@'
mutate 'bootstrap: restart claims success whatever launchd did' lib/manage.sh install.tests.sh \
  's@^  if ! tk_bootstrap "\$(tk_domain)" "\$TK_PLIST"; then@  if false; then@'
mutate 'bootstrap: the boot-tier restart claims success whatever launchd did' lib/manage.sh install.tests.sh \
  's@^    if ! tk_bootstrap system "\$TK_DAEMON_PLIST"; then@    if false; then@'
mutate 'bootstrap: the reason launchd gave is thrown away' lib/manage.sh install.tests.sh \
  's@TK_BOOTSTRAP_ERR=\$(sudo "\$TK_LAUNCHCTL" bootstrap system "\$_plist" 2>&1) || _rc=\$?@sudo "$TK_LAUNCHCTL" bootstrap system "$_plist" >/dev/null 2>\&1 || _rc=$?@'
mutate 'bootstrap: the trigger check restores the watcher silently, or not at all' lib/checks.sh checks.tests.sh \
  's@^  if ! tk_bootstrap "\$(tk_domain)" "\$TK_PLIST"; then@  if false; then@'
mutate 'bootstrap: a second door into launchd, outside the seam' lib/manage.sh conventions.tests.sh \
  's@^cmd_restart() {@cmd_restart() {\n  "$TK_LAUNCHCTL" bootstrap "$(tk_domain)" "$TK_PLIST" >/dev/null 2>\&1 || true@'
mutate 'bootstrap: a caller ignores whether the load worked' lib/manage.sh conventions.tests.sh \
  's@^  if ! tk_bootstrap "\$(tk_domain)" "\$TK_PLIST"; then@  tk_bootstrap "$(tk_domain)" "$TK_PLIST" || true\n  if false; then@'

# --- the rule 5 gate check is itself testable ---------------------------------

mutate 'sidechannel: the scan counts commented mentions as doors' \
  tests/conventions.tests.sh conventions.tests.sh \
  's|grep -vc|grep -c|'

# --- a skip is never a pass ---------------------------------------------------
#
# The bug these reintroduce shipped: run.sh printed a file's output only on FAIL,
# so a SKIP written to stderr vanished and exit 0 was counted as a pass.

mutate 'harness: a file that did not run is counted as a pass' tests/run.sh conventions.tests.sh \
  's@^    2) echo "  SKIP  \$base"@    2) echo "  PASS  $base"@'
mutate 'harness: a skipped case is hidden when its file passes' tests/run.sh conventions.tests.sh \
  '/^    0) echo "  PASS  \$base"$/{n;s@^       say_skips "\$out"$@       :@;}'
mutate 'harness: the summary counts a skipped file among those that passed' tests/run.sh conventions.tests.sh \
  's@^ran=\$(( n - nskipped ))$@ran=$n@'
mutate 'harness: a skip raises the exit code, as if it were a failure' tests/run.sh conventions.tests.sh \
  's@^exit \$failed$@exit $(( failed + nskipped ))@'
mutate 'harness: exit_skipped exits 0, which is indistinguishable from a pass' tests/lib.sh conventions.tests.sh \
  's@^  exit 2$@  exit 0@'
mutate 'harness: finish drops the skipped-case tally' tests/lib.sh conventions.tests.sh \
  's@^  if \[ "\$SKIPPED" -gt 0 \]; then@  if false; then@'

# --- launchd is reached through one name -------------------------------------

mutate 'launchd: a bare launchctl bypasses the seam the suite records through' lib/manage.sh conventions.tests.sh \
  's@^  "\$TK_LAUNCHCTL" bootout "\$DOMAIN/\$TK_LABEL"@  launchctl bootout "$DOMAIN/$TK_LABEL"@'

# --- revision 2: the method choice, and esc on the top menu ------------------

mutate 'method: the choice is never offered up front' lib/walkthrough.sh walkthrough.tests.sh \
  's@  if _di=$(wt_dialect_for "$(printf .%s. "$_key" | cut -d: -f1)"); then@  if false; then@'
mutate 'method: a vendor with a dialect is given it instead of being asked' lib/walkthrough.sh walkthrough.tests.sh \
  '/^wt_choose_method() {/{n;n;n;n;n;s%.*%  printf "lg-alt\\n"; return 0%;}'
mutate 'method: choosing it does not change which values are offered' lib/walkthrough.sh walkthrough.tests.sh \
  's%    _method=$(wt_choose_method "$_di" "$_method")%    wt_choose_method "$_di" "$_method" >/dev/null%'
mutate 'method: the escalation is one-way again' lib/checks.sh checks.tests.sh \
  's%    if \[ "${WT_A_METHOD\[$_i\]}" != "$_alt" \]; then%    if true; then%'
mutate 'esc: the top menu ignores esc again' lib/menu.sh menu.tests.sh \
  's%        if \[ "$_escapeto" -ge 0 \]; then%        if false; then%'
mutate 'esc: the top menu ACTIVATES the way out instead of moving to it' lib/menu.sh menu.tests.sh \
  's%        if \[ "$_escapable" = "1" \]; then printf ..n. >&2; MENU_PICK=-1; return 0; fi%        if [ "$_escapable" = "1" ] || [ "$_escapeto" -ge 0 ]; then printf "\\n" >\&2; MENU_PICK=$_escapeto; return 0; fi%'

# --- redraw: the reported 80-column corruption -------------------------------

mutate 'redraw: select_many concatenates its detail instead of wrapping' lib/menu.sh keys.tests.sh \
  's@      _buf="$_buf$(menu_build_row "$_i" "$_m" "$_width" "$_itemw" -1 "$_b")@      _buf="$_buf$(printf "%s %s %s  %s" "$_m" "$_b" "${MENU_ITEMS[$_i]}" "${MENU_DETAIL[$_i]}")@'
mutate 'redraw: the frame pads to width instead of erasing the line' lib/menu.sh keys.tests.sh \
  "s@    printf '%s.033\[K.n' \"\$_l\" >&2@    printf '%-*s\\n' \"\$_width\" \"\$_l\" >\&2@"

# --- revision 4: the boot tier ----------------------------------------------

mutate 'tier: the boot row is disabled again' lib/walkthrough.sh walkthrough.tests.sh \
  "s@  menu_add 'From boot' 'needs your password once, to install'@  menu_add 'From boot' 'x'; menu_disable 0@"
mutate 'tier: choosing boot silently writes login' lib/walkthrough.sh walkthrough.tests.sh \
  's@    0) WT_TIER=boot ;;@    0) WT_TIER=login ;;@'

mutate 'tier: configure records the tier but never applies it' trigger-kvm walkthrough.tests.sh \
  's@cmd_configure "$FRESH"; tk_apply_tier "$CONFIG"; tk_say_done; exit 0 ;;@cmd_configure "$FRESH"; tk_say_done; exit 0 ;;@'
mutate 'tier: the daemon runs as root instead of the user' lib/manage.sh walkthrough.tests.sh \
  's@  <key>UserName</key><string>$(id -un)</string>@  <key>UserName</key><string>root</string>@'
mutate 'tier: a declined password leaves the config claiming boot' lib/manage.sh walkthrough.tests.sh \
  "s@      sed -i '' 's/.*install@      : 's/^\\([[:space:]]*\\)install@"

# --- revision 8: status shows the input map, and asks the lock ---------------

mutate 'status: the watcher question is answered by counting processes' lib/manage.sh status.tests.sh \
  's@--lock-status@--list@'
mutate 'status: a lock it cannot open reads as no watcher' event-watch.c watcher.tests.sh \
  's@        printf("running.n");   // present and unopenable@        printf("none\\n"); //@'
mutate 'status: asking about the lock creates it' event-watch.c watcher.tests.sh \
  's@    int fd = open(path, O_RDWR);@    int fd = open(path, O_RDWR | O_CREAT, 0644);@'
mutate 'status: the input map is shown with no warning that it is unverified' lib/manage.sh status.tests.sh \
  "s@    printf '           ^ asserted, never verified@    : '@"
mutate 'status: inputs ordered by value instead of by computer' lib/manage.sh status.tests.sh \
  's@      for _c in \$(config_known_computers); do@      for _c in $(config_input_map "$_l" | sort -k2 | cut -f1); do@'
mutate 'status: this computer is not marked on the map' lib/manage.sh status.tests.sh \
  's@        if \[ "\$_c" = "\$_this" \]; then _c="\$_c (this one)"; fi@        :@'
mutate 'status: the warning is printed even with nothing configured' lib/manage.sh status.tests.sh \
  "s@    printf 'inputs   : none configured.n'@    printf 'inputs   : none configured\\n           asserted, never verified. Fix: trigger-kvm configure\\n'@"
mutate 'status: a panel with no inputs is dropped from the map' lib/manage.sh status.tests.sh \
  "s@      \[ -n \"\$_row\" \] || _row='no inputs configured'@      [ -n \"\$_row\" ] || continue@"

# --- revision 11: a writer must not write what it cannot read back -----------

mutate 'config: a written value is not sanitised at all' lib/config.sh config.tests.sh \
  's@config_line() {@config_line() { printf "%-*s = %s\\n" "${3:-0}" "$1" "$2"; return 0@'
mutate 'config: # is kept, so the value is cut on the next read' lib/config.sh config.tests.sh \
  "s@  _v=\${_v//\[\$'#\\\\r\\\\n\\\\t\\\\v\\\\f'\]/ }@  _v=\${_v//[\$'\\\\r\\\\n\\\\t\\\\v\\\\f']/ }@"
mutate 'config: a newline is kept, so one value becomes two lines' lib/config.sh config.tests.sh \
  "s@  _v=\${_v//\[\$'#\\\\r\\\\n\\\\t\\\\v\\\\f'\]/ }@  _v=\${_v//[\$'#\\\\r\\\\t\\\\v\\\\f']/ }@"
mutate 'config: the writer does not trim, so the reader has to' lib/config.sh config.tests.sh \
  's@  _v=\${_v# }; _v=\${_v% }@  :@'
mutate 'config: the key padding is written into the key' lib/config.sh config.tests.sh \
  "s@  printf '%-\*s = %s.n' \"\\\${3:-0}\" \"\$1\" \"\$(config_to_value \"\$2\")\"@  printf '%s = %s\\\\n' \"\$(printf '%-*s' \"\${3:-0}\" \"\$1\" | sed 's/ /_/g')\" \"\$(config_to_value \"\$2\")\"@"
mutate 'config: the panel name is written straight through again' lib/walkthrough.sh conventions.tests.sh \
  "s@      config_line \"display.\$_l.name\"    \"\\\${WT_A_NAME\[\$_i\]}\"    \"\$_w\"@      printf 'display.%s.name    = %s\\\\n' \"\$_l\" \"\${WT_A_NAME[\$_i]}\"@"
mutate 'config: carried-through hand edits skip the writer' lib/walkthrough.sh conventions.tests.sh \
  "s@    config_line \"\$_k\" \"\$_v\"@    printf 'k%s = %s\\\\n' \"\${_k#?}\" \"\$_v\"@"

# --- revision 9: transport is a separate axis from method --------------------

mutate 'transport: an unrecognised one is defaulted instead of refused' lib/display.sh switch.tests.sh \
  's@  if \[ "\$_transport" != "\$DDC_TRANSPORT" \]; then@  if false; then@'
mutate 'transport: refused, then it falls through and sends anyway' lib/display.sh switch.tests.sh \
  "s@    tk_log \"REFUSING \$_label: transport '\$_transport' does not@    tk_log \"transport '\$_transport' does not@;s@^    return 1\$@    :@"
mutate 'transport: an ABSENT one is refused, breaking every old config' lib/display.sh switch.tests.sh \
  's@config_display_field "\$_label" transport "\$DDC_TRANSPORT"@config_get "display.$_label.transport"@'
mutate 'transport: the walkthrough stops recording what it used' lib/walkthrough.sh walkthrough.tests.sh \
  's@      config_line "display.\$_l.transport" "\$DDC_TRANSPORT" "\$_w"@      :@'
mutate 'transport: a hand-written transport is dropped on Save' lib/walkthrough.sh walkthrough.tests.sh \
  's@        case \$_rest in vendor|product|name|method|transport|input\.\*) continue ;; esac ;;@        case $_rest in vendor|product|name|method|input.*) continue ;; esac ;;@'

# --- revision 13: an identity naming more than one attached panel ------------

mutate 'twins: the count sums instead of counting one identity' lib/display.sh status.tests.sh \
  "s@  printf '%s\\\\n' \"\$1\" | cut -d'|' -f1,2 | tr '|' ':' | grep -cxF \"\$2\" || true@  printf '1\\\\n'@"
mutate 'twins: status says nothing about an ambiguous panel' lib/manage.sh status.tests.sh \
  's@    \[ "\$_n" -gt 1 \] || continue@    continue@'
mutate 'twins: status reports an ABSENT panel as ambiguous too' lib/manage.sh status.tests.sh \
  's@    \[ "\$_n" -gt 1 \] || continue@    [ "$_n" -ne 1 ] || continue@'
mutate 'twins: status offers configure as the fix for something it cannot fix' lib/manage.sh status.tests.sh \
  "s@    printf '  Unplugging one is the only remedy today..n'@    printf '  Fix: trigger-kvm configure\\\\n'@"
mutate 'twins: the walkthrough lets an ambiguous identity be picked' lib/walkthrough.sh walkthrough.tests.sh \
  's@        menu_disable "\$_i"@        :@'
mutate 'twins: the walkthrough merges the two panels into one row' lib/walkthrough.sh walkthrough.tests.sh \
  's@      if \[ "\${WT_F_TWINS\[\$_i\]}" -gt 1 \]; then@      if [ "${WT_F_TWINS[$_i]}" -gt 1 ] \&\& [ "$_ambiguous" = 0 ]; then@'
mutate 'twins: the list hides the second panel behind the first' trigger-kvm switch.tests.sh \
  's@    \[ "\$_n" -gt 1 \] && _as=@    [ "$_n" -gt 99 ] \&\& _as=@'
mutate 'twins: two found rows build two answer records for one panel' lib/walkthrough.sh walkthrough.tests.sh \
  's@    if wt_answer_index "\${WT_F_KEY\[\$_i\]}" >/dev/null; then _i=\$(( _i + 1 )); continue; fi@    :@'
mutate 'twins: the cursor lands on a row it will refuse' lib/walkthrough.sh walkthrough.tests.sh \
  's@      if \[ "\${WT_F_TWINS\[\$_i\]}" -le 1 \] && ! wt_answer_index@      if ! wt_answer_index@'

echo
if [ "$survived" = "0" ]; then
  echo "all $checked mutations were caught"
elif [ "$unjudged" = "$survived" ]; then
  echo "$unjudged of $checked mutations UNJUDGED -- their suite is red unmutated, so nothing was proved"
else
  echo "$survived of $checked mutations SURVIVED ($unjudged unjudged) -- those assertions do not earn their place"
fi
exit "$survived"
