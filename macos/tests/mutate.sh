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

survived=0
checked=0

# mutate <name> <file> <suite> <sed-expression>
mutate() {
  name=$1; file=$2; suite=$3; expr=$4
  case $name in *"$FILTER"*) ;; *) return 0 ;; esac

  target="$MAC_DIR/$file"
  cp "$target" "$target.mutbak"
  # shellcheck disable=SC2064
  trap "mv -f '$target.mutbak' '$target' 2>/dev/null" EXIT

  sed -i '' "$expr" "$target"
  if cmp -s "$target" "$target.mutbak"; then
    echo "  ERROR  mutation did not apply: $name"
    survived=$(( survived + 1 ))
  else
    checked=$(( checked + 1 ))
    if bash "$HERE/$suite" >/tmp/tk-mutate.out 2>&1; then
      echo "  SURVIVED  $name"
      survived=$(( survived + 1 ))
    else
      echo "  caught    $name  ->  $(grep -m1 'FAIL' /tmp/tk-mutate.out | sed 's/^ *FAIL *//')"
    fi
  fi

  mv -f "$target.mutbak" "$target"
  trap - EXIT
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

echo
if [ "$survived" = "0" ]; then
  echo "all $checked mutations were caught"
else
  echo "$survived of $checked mutations SURVIVED -- those assertions do not earn their place"
fi
exit "$survived"
