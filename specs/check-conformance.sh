#!/bin/bash
#
# Does an implementation contain every normative string its spec pins down?
#
#     specs/check-conformance.sh <spec.md> <source> [source...]
#
# Exits 0 when every fragment is present, 1 otherwise, listing what is missing.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT. It proves a string is PRESENT in the
# sources. It does not prove that string is REACHABLE -- a shadowed function can
# still contain it. That gap is real and has already bitten this project once, in
# windows/install.ps1, where a duplicate definition left the older wording live
# and the newer wording dead in the same file. Pair this with a structural check
# for duplicate definitions.
#
# The marker format is the cross-platform contract; this script is only the macOS
# implementation of the check. Windows implements the same check in PowerShell,
# the same way each platform implements its own transport.

set -uo pipefail

SPEC=${1:-}
shift 2>/dev/null || true
if [ -z "$SPEC" ] || [ $# -eq 0 ]; then
  echo "usage: check-conformance.sh <spec.md> <source> [source...]" >&2
  exit 2
fi

SOURCES=$(cat "$@")

# Every line inside a ```normative fence, split on {placeholders}.
#
# The length floor applies only to fragments produced BY SPLITTING. A whole line
# with no placeholder in it was written down deliberately and is distinctive
# enough to pin at any length -- "--- monitors ---" is 16 characters and could
# not match by accident. A piece left between two placeholders often is not, so
# those carry an 18-character floor.
#
# The blanket floor was wrong: it silently dropped every section header in the
# spec, so renaming one changed nothing and the check stayed green. Found by a
# mutation that survived.
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
  /^```normative[ \t]*$/ { inblock = 1; next }
  /^```/                 { inblock = 0; next }
  inblock {
    line = $0
    if (line !~ /\{[^}]*\}/) {          # a whole line: keep it at any length
      if (length(line) >= 6) print line
      next
    }
    while (match(line, /\{[^}]*\}/)) {  # a split piece: needs to be distinctive
      piece = substr(line, 1, RSTART - 1)
      if (length(piece) >= 18) print piece
      line = substr(line, RSTART + RLENGTH)
    }
    if (length(line) >= 18) print line
  }
' "$SPEC" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
EOF

if [ "$MISSING" -gt 0 ]; then
  printf '%s of %s normative fragments from %s are missing\n' \
         "$MISSING" "$TOTAL" "$SPEC" >&2
  exit 1
fi
printf 'all %s normative fragments from %s are present\n' "$TOTAL" "$SPEC"
