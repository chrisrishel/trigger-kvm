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
cat >"$FAKE_DIR/short-spec.md" <<'EOS'
```normative
{a} ok {b}
```
EOS
set +e
"$CHECK" "$FAKE_DIR/short-spec.md" "${SOURCES[@]}" >/dev/null 2>&1
rc=$?
set -e
assert_equal 0 "$rc" 'a two-character fragment must not be treated as normative'

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
