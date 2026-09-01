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

for spec in configure config-format detector; do
  it "this implementation conforms to specs/$spec.md"
  out=$("$CHECK" "$SPECS/$spec.md" "${SOURCES[@]}" 2>&1) || true
  case $out in
    *"are missing"*) _fail "$out" ;;
  esac
done

# =============================================================================
# The shared reader fixture (specs/config-format.md, "The shared fixture")
# =============================================================================
#
# The adversarial cases live once, in specs/, and each platform parses them with
# its own reader. "Conforms to config-format.md" passed vacuously before this:
# that file has no normative strings, and three reader disagreements were found
# by hand that this would have caught.

# shellcheck source=../lib/config.sh
. "$MAC_DIR/lib/config.sh"

it 'this reader reproduces the shared fixture exactly'
config_load "$SPECS/config-fixture/input.conf"
actual=$(printf '%s\n' "$CONFIG_DATA" | cut -f1 | awk 'NF && !seen[$0]++' |
         while IFS= read -r k; do printf '%s\t%s\n' "$k" "$(config_get "$k")"; done)
diffout=$(diff "$SPECS/config-fixture/expected.tsv" <(printf '%s\n' "$actual") || true)
assert_equal '' "$diffout" 'reader output differs from specs/config-fixture/expected.tsv (< expected, > got)'

it 'and its converters agree with every row of the values table'
bad=''
# Split by hand: with IFS set to a tab, `read` collapses consecutive tabs, and
# the row whose input is EMPTY would shift its fields.
while IFS= read -r row; do
  [ -n "$row" ] || continue
  kind=${row%%$'\t'*}; rest=${row#*$'\t'}
  input=${rest%%$'\t'*}; want=${rest#*$'\t'}
  case $kind in
    byte) got=$(config_to_byte "$input" 2>/dev/null) || got=REFUSE ;;
    word) got=$(config_to_word "$input" 2>/dev/null) || got=REFUSE ;;
    *)    got="unknown kind $kind" ;;
  esac
  [ "$got" = "$want" ] || bad="$bad
  $kind '$input': expected $want, got $got"
done <"$SPECS/config-fixture/values.tsv"
assert_equal '' "$bad" "converter disagreements with specs/config-fixture/values.tsv:$bad"

it 'the fixture still carries its byte-order mark and CRLF lines'
# A checkout that normalised them would make the test above prove less than it
# says. .gitattributes marks the file -text; this notices if that is undone.
assert_equal 'efbbbf' "$(head -c 3 "$SPECS/config-fixture/input.conf" | xxd -p)"
assert_true "$([ "$(grep -c $'\r' "$SPECS/config-fixture/input.conf")" -ge 3 ] && echo 0 || echo 1)" 'CRLF lines must survive checkout'

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

it 'the checker measures a fragment AFTER trimming it'
# Measured untrimmed, "     Nope" is 9 characters and gets pinned; trimmed it is
# 4 and falls under the whole-line floor. The Windows checker trims first, so
# the two disagreed on the same spec until this was made the rule.
# shellcheck disable=SC2016  # the backticks and braces are the spec's own syntax
printf '# x\n\n```normative\n     Nope\n{a}   qqqqqqqqqqqqqqqq   {b}\n```\n' >"$FAKE_DIR/trim-spec.md"
set +e
out=$("$CHECK" "$FAKE_DIR/trim-spec.md" "${SOURCES[@]}" 2>&1)
rc=$?
set -e
assert_equal 0 "$rc" "both fragments are under their floors once trimmed: $out"
assert_no_match "$out" 'MISSING'

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
# The LARGEST revision, not the first heading found (specs/README.md): the two
# checkers used to differ here, and an entry appended at the bottom read as a
# downgrade on this side and a new revision on the other.
changelog_head() { sed -n 's/^## Revision \([0-9][0-9]*\).*/\1/p' "${1:-$SPECS/CHANGELOG.md}" | sort -n | tail -1; }

it 'the changelog head is the largest revision, wherever it sits'
printf '## Revision 2 -- x\n\n## Revision 7 -- y\n\n## Revision 5 -- z\n' >"$FAKE_DIR/changelog.md"
assert_equal 7 "$(changelog_head "$FAKE_DIR/changelog.md")"

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
