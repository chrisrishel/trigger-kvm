#!/bin/bash
#
# Conformance: does this implementation contain every normative string the specs
# pin down?
#
# The specs in ../../specs are what this is built FROM. When they disagree with
# the code, the code is wrong -- so a spec edit fails here until the
# implementation catches up, which is what makes "spec first" a rule rather than
# a hope.
#
# See ../../specs/README.md for the marker format and for what this check does
# NOT prove: it proves a string is PRESENT, not that it is REACHABLE.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPECS="$MAC_DIR/../specs"
CHECK="$SPECS/check-conformance.sh"

fake_setup

# An array, so the paths stay separate arguments without relying on word
# splitting: one of them could one day contain a space.
SOURCES=(
  "$MAC_DIR"/lib/*.sh
  "$MAC_DIR/trigger-kvm"
  "$MAC_DIR/install.sh"
)

it 'the checker exists and is executable'
assert_true "$([ -x "$CHECK" ] && echo 0 || echo 1)" "$CHECK"

for spec in configure config-format; do
  it "this implementation conforms to specs/$spec.md"
  out=$("$CHECK" "$SPECS/$spec.md" "${SOURCES[@]}" 2>&1) || true
  case $out in
    *"are missing"*) _fail "$out" ;;
  esac
done

it 'the checker actually fails when a normative string is absent'
# A conformance check that cannot fail is decoration. Prove it bites, against a
# throwaway spec rather than by breaking a real one.
cat >"$FAKE_DIR/fake-spec.md" <<'EOS'
# A spec nothing implements

```normative
this exact sentence appears in no source file anywhere
```
EOS
set +e
out=$("$CHECK" "$FAKE_DIR/fake-spec.md" "${SOURCES[@]}" 2>&1)
rc=$?
set -e
assert_equal 1 "$rc" 'a missing fragment must fail'
assert_match "$out" 'this exact sentence appears in no source file'

it 'the checker ignores fragments too short to pin anything down'
# The piece left after splitting must be one the sources do NOT contain --
# "ok" was used here once, and it is a substring of checks.sh, so the fixture
# passed with the floor removed entirely. A fixture for absence has to be
# absent.
cat >"$FAKE_DIR/short-spec.md" <<'EOS'
```normative
{a} zqxjv {b}
```
EOS
set +e
"$CHECK" "$FAKE_DIR/short-spec.md" "${SOURCES[@]}" >/dev/null 2>&1
rc=$?
set -e
assert_equal 0 "$rc" 'a five-character split piece must not be treated as normative'

it 'but a WHOLE line is pinned at any length'
# The two floors are different on purpose: "--- monitors ---" is 16 characters,
# under the floor for split pieces, and is exactly what a section header check
# exists to catch. A blanket floor silently dropped every header in the spec.
cat >"$FAKE_DIR/line-spec.md" <<'EOS'
```normative
--- nowhere ---
```
EOS
set +e
out=$("$CHECK" "$FAKE_DIR/line-spec.md" "${SOURCES[@]}" 2>&1)
rc=$?
set -e
assert_equal 1 "$rc" 'a 15-character whole line must still be reported missing'
assert_match "$out" 'nowhere'

# =============================================================================
# The spec revision this implementation claims to implement
# =============================================================================
#
# The conformance check above is blind to two kinds of spec change: a
# behavioural one with no new wording to grep for, and a REMOVED string, since
# it only tests presence. The revision closes both -- and it is how a platform
# finds out it is behind without anyone having to tell it, which is what makes a
# third implementation cost nothing.

spec_revision()  { sed -n 's/^revision[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" | tail -1; }
changelog_head() { sed -n 's/^## Revision \([0-9][0-9]*\).*/\1/p' "$SPECS/CHANGELOG.md" | head -1; }

# assert_match is a substring test, not a regex one -- so "is this a number?"
# is asked with a case, not a pattern string.
is_number() { case ${1:-} in ''|*[!0-9]*) echo 1 ;; *) echo 0 ;; esac; }

it 'this implementation records the spec revision it implements'
mine=$(spec_revision "$MAC_DIR/SPEC-REVISION")
assert_true "$(is_number "$mine")" "macos/SPEC-REVISION must carry a number, got '$mine'"

it 'the changelog names a revision'
head=$(changelog_head)
assert_true "$(is_number "$head")" "specs/CHANGELOG.md must open with '## Revision N', got '$head'"

it 'this implementation is not BEHIND the specs'
# When this fails, read the changelog entries between the two numbers: they are
# what this platform owes. Bump SPEC-REVISION in the commit that lands them.
if [ "$mine" -lt "$head" ]; then
  _fail "macOS implements spec revision $mine; specs/CHANGELOG.md is at $head.
         Outstanding: $(awk -v a="$mine" -v b="$head" '
           /^## Revision /{ n = $3 + 0; want = (n > a && n <= b) }
           want && /^## Revision /{ printf "  rev %s", n }
         ' "$SPECS/CHANGELOG.md")"
fi

it 'and is not AHEAD of them either'
# Ahead means someone implemented a change without writing it down, which is the
# spec-first rule broken in the direction that leaves no trace.
assert_true "$([ "$mine" -le "$head" ] && echo 0 || echo 1)" \
  "macos/SPEC-REVISION is $mine but the changelog only reaches $head"

it 'the checker splits on placeholders rather than matching them literally'
cat >"$FAKE_DIR/ph-spec.md" <<'EOS'
```normative
{some placeholder} here, so you can read this. {another}
```
EOS
set +e
"$CHECK" "$FAKE_DIR/ph-spec.md" "${SOURCES[@]}" >/dev/null 2>&1
rc=$?
set -e
assert_equal 0 "$rc" 'the literal between placeholders is what is checked'

finish
