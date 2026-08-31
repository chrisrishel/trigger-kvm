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
# This is not run by run.sh. It edits files in place, so it is a thing you run
# deliberately, and it restores every file it touches even when a test wedges.

set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
MAC_DIR=$(dirname "$HERE")
FILTER=${1:-}
[ "$FILTER" = "--restore-only" ] && FILTER="__none__"

survived=0
checked=0

# A run that is killed outright (SIGKILL, a watchdog, a closed terminal) cannot
# run its trap, and would leave a MUTATED source and a mutated binary behind --
# which then silently becomes what the next test run measures. That happened
# once and cost an hour chasing a lock bug that did not exist. So: restore
# anything left over before doing anything else, and say so.
for bak in "$MAC_DIR"/*.mutbak "$MAC_DIR"/lib/*.mutbak "$MAC_DIR"/tests/*.mutbak; do
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
  cp "$target" "$target.mutbak"
  # shellcheck disable=SC2064
  trap "mv -f '$target.mutbak' '$target' 2>/dev/null; make -B -C '$MAC_DIR' -s >/dev/null 2>&1" EXIT INT TERM HUP

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
    if bash "$HERE/$suite" >/tmp/tk-mutate.out 2>&1 & p=$!
       ( sleep "${TK_MUTATE_TIMEOUT:-300}"; kill -9 $p 2>/dev/null ) >/dev/null 2>&1 &
       w=$!; wait $p; rc=$?; kill $w 2>/dev/null; [ $rc -eq 0 ]; then
      echo "  SURVIVED  $name"
      survived=$(( survived + 1 ))
    else
      echo "  caught    $name  ->  $(grep -m1 'FAIL' /tmp/tk-mutate.out | sed 's/^ *FAIL *//')"
    fi
  fi

  mv -f "$target.mutbak" "$target"
  case $file in *.c) make -B -C "$MAC_DIR" -s >/dev/null 2>&1 || true ;; esac
  trap - EXIT INT TERM HUP
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
  's@      Escape) if \[ "$_escapable" = "1" \]; then printf .\\n. >&2; MENU_PICK=-1; return 0; fi ;;@      Escape) printf "\\n" >\&2; MENU_PICK=-1; return 0 ;;@'
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
  '/^select_many() {/{n;s%^  local .*%  :%;}'
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
  's%^revision = 1%revision = 0%'
mutate 'revision: this platform claims a revision that does not exist' SPEC-REVISION spec.tests.sh \
  's%^revision = 1%revision = 99%'

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

echo
if [ "$survived" = "0" ]; then
  echo "all $checked mutations were caught"
else
  echo "$survived of $checked mutations SURVIVED -- those assertions do not earn their place"
fi
exit "$survived"
