#!/bin/bash
#
# Does an implementation contain every normative string its spec pins down?
#
#     specs/check-conformance.sh <spec.md> <source> [source...]
#
# Exits 0 when every fragment is present, 1 otherwise, listing what is missing.
#
# It proves a string is PRESENT in the sources' code lines, not that it is
# REACHABLE: a shadowed function still contains it, so each suite pairs this
# with a duplicate-definition scan (specs/README.md). Comment lines are not
# source. The marker format is the cross-platform contract; this script is the
# macOS implementation of the check, and Windows has its own.

set -uo pipefail

SPEC=${1:-}
shift 2>/dev/null || true
if [ -z "$SPEC" ] || [ $# -eq 0 ]; then
  echo "usage: check-conformance.sh <spec.md> <source> [source...]" >&2
  exit 2
fi

if [ ! -r "$SPEC" ]; then
  echo "check-conformance.sh: cannot read $SPEC" >&2
  exit 2
fi

# Code lines only: a fragment that survives only in a comment is not present.
SOURCES=$(cat "$@" | grep -v '^[[:space:]]*#')

# Every line inside a ```normative fence, split on {placeholders}. A whole line
# is pinned at any length (6, so a stray word is not); a piece produced by
# splitting carries an 18-character floor, because a short one matches by
# accident.
MISSING=0
TOTAL=0

while IFS= read -r frag; do
  [ -n "$frag" ] || continue
  TOTAL=$(( TOTAL + 1 ))
  case $SOURCES in
    *"$frag"*) ;;
    *) MISSING=$(( MISSING + 1 )); printf '  MISSING: %s\n' "$frag" >&2 ;;
  esac
done <<EOF
$(awk '
  # Lengths are measured after trimming (specs/README.md).
  function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
  /^```normative[ \t]*$/ { inblock = 1; next }
  /^```/                 { inblock = 0; next }
  inblock {
    line = $0
    if (line !~ /\{[^}]*\}/) {          # a whole line: keep it at any length
      t = trim(line)
      if (length(t) >= 6) print t
      next
    }
    while (match(line, /\{[^}]*\}/)) {  # a split piece: needs to be distinctive
      piece = trim(substr(line, 1, RSTART - 1))
      if (length(piece) >= 18) print piece
      line = substr(line, RSTART + RLENGTH)
    }
    t = trim(line)
    if (length(t) >= 18) print t
  }
' "$SPEC")
EOF

if [ "$MISSING" -gt 0 ]; then
  printf '%s of %s normative fragments from %s are missing\n' \
         "$MISSING" "$TOTAL" "$SPEC" >&2
  exit 1
fi
printf 'all %s normative fragments from %s are present\n' "$TOTAL" "$SPEC"
