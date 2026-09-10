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

# EVERYTHING THE USER CAN SEE, derived rather than listed, and an array so the
# paths stay separate arguments: one of them could one day contain a space.
#
# The C belongs here. `wt_check_triggers` prints the framing and then hands the
# terminal to `event-watch --test-trigger`, which prints its own wording, so the
# detector is part of the user surface and detector.md is in the loop below --
# a normative string added there would otherwise be reported missing from the
# one file the check does not read. Windows has no such gap only because its
# detector is a .ps1 and its list globs *.ps1.
#
# `trigger-kvm` is named because it is the one file here with no extension for a
# glob to find. Everything else joins by existing, and the coverage self-test
# below is what says so.
SOURCES=(
  "$MAC_DIR"/lib/*.sh
  "$MAC_DIR"/*.sh
  "$MAC_DIR"/*.c
  "$MAC_DIR/trigger-kvm"
)

it 'the checker exists and is executable'
assert_true "$([ -x "$CHECK" ] && echo 0 || echo 1)" "$CHECK"

# The list of specs is DERIVED, never written down. A hardcoded list is checked
# by nobody the day a spec file is added -- specs/status.md landed in revision 8
# and sat unchecked here because this loop had not been told about it, and the
# changelog entry was the only thing that could have said so.
#
# Two files in specs/ are not contracts an implementation conforms to:
# README.md is ABOUT the marker format, so its ```normative block is the worked
# example rather than an obligation, and CHANGELOG.md is the revision ledger.
# Naming those two is safe in a way that naming the specs is not -- a new spec
# joins the loop by existing, while a new meta-file would fail loudly here and
# be added deliberately.
# The checker's exit status is the verdict; its output names what is missing.
conforms() {
  local _out _rc
  set +e; _out=$("$CHECK" "$1" "${SOURCES[@]}" 2>&1); _rc=$?; set -e
  [ "$_rc" = 0 ] || _fail "$_out"
}

CHECKED=0
for spec in "$SPECS"/*.md; do
  case ${spec##*/} in README.md | CHANGELOG.md) continue ;; esac
  CHECKED=$(( CHECKED + 1 ))
  it "this implementation conforms to specs/${spec##*/}"
  conforms "$spec"
done

it 'a checker that could not run is not a pass'
# A spec it cannot read exits 2 with no "missing" line; the verdict must still
# be red. Run in a subshell so this file's own tally is not touched.
set +e; ( FAILED=0; conforms "$FAKE_DIR/no-such-spec.md" 2>/dev/null; exit "$FAILED" ); rc=$?; set -e
assert_true "$([ "$rc" -gt 0 ] && echo 0 || echo 1)" 'an unreadable spec must fail the verdict'

# Self-test of the derivation above: every .md in specs/ is either checked or one
# of the two named exclusions. Catches the glob matching nothing, and catches an
# exclusion list that has quietly grown to swallow a real spec.
it 'every spec file is covered, so none can be added unchecked'
assert_equal "$(find "$SPECS" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" \
             "$(( CHECKED + 2 ))" \
             'specs/*.md is not fully accounted for by the conformance loop'

# The same self-test one level down, on the SOURCES. The globs are not
# recursive and the file with no extension is named by hand, so a source in a
# new subdirectory would be read by nobody -- and the check would go on
# reporting conformance about wording it could not see. Windows hit exactly that
# when install.ps1 was split into lib\.
it 'every source a user-visible string can live in is read by the checker'
missed=''
while IFS= read -r f; do
  found=''
  # Element by element, not against "${SOURCES[*]}": joining on a space is the
  # one thing the array above exists to avoid.
  for s in "${SOURCES[@]}"; do
    if [ "$s" = "$f" ]; then found=1; fi
  done
  [ -n "$found" ] || missed="$missed
  $f"
done <<EOS
$(find "$MAC_DIR" -type f \( -name '*.sh' -o -name '*.c' -o -name trigger-kvm \) \
       -not -path "$MAC_DIR/tests/*")
EOS
assert_equal '' "$missed" "these files hold wording the conformance check cannot see:$missed"

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

it 'the checker refuses a spec it cannot read, rather than reporting all 0 present'
set +e; out=$("$CHECK" "$FAKE_DIR/no-such-spec.md" "${SOURCES[@]}" 2>&1); rc=$?; set -e
assert_equal 2 "$rc" "$out"
assert_no_match "$out" 'are present'

it 'a fragment that survives only in a comment is reported missing'
# A comment is not source: a config-file header or a note that quotes the
# spec's words must not stand in for the wording the person sees.
printf '%s\n' '# --- somewhere only a comment says ---' >"$FAKE_DIR/commented.sh"
# shellcheck disable=SC2016  # the backticks are the spec's own fence syntax
printf '# x\n\n```normative\n--- somewhere only a comment says ---\n```\n' >"$FAKE_DIR/comment-spec.md"
set +e; out=$("$CHECK" "$FAKE_DIR/comment-spec.md" "$FAKE_DIR/commented.sh" 2>&1); rc=$?; set -e
assert_equal 1 "$rc" "$out"

it 'and the same is true of a C comment, now that the C is read'
# `#` alone would have made every line of event-watch.c's prose count as source.
printf '/*\n * --- somewhere only a comment says ---\n */\n// --- somewhere only a comment says ---\nint main(void){return 0;}\n' >"$FAKE_DIR/commented.c"
set +e; out=$("$CHECK" "$FAKE_DIR/comment-spec.md" "$FAKE_DIR/commented.c" 2>&1); rc=$?; set -e
assert_equal 1 "$rc" "$out"

it 'but a shell case branch is code, not a comment, though it opens with *'
# The C rule strips a leading `*` (a block-comment continuation). Applied to
# shell it would delete every `*)` branch, and the wording inside one with it.
# shellcheck disable=SC2016  # $1 belongs to the fixture, not to this script
printf 'f() { case $1 in\n  *) printf "%%s" "--- somewhere only a comment says ---" ;;\nesac\n}\n' >"$FAKE_DIR/branch.sh"
set +e; out=$("$CHECK" "$FAKE_DIR/comment-spec.md" "$FAKE_DIR/branch.sh" 2>&1); rc=$?; set -e
assert_equal 0 "$rc" "$out"

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
