#!/bin/bash
#
# Structural rules, checked mechanically rather than by reading.
#
# Both of these are properties of the SHAPE of the code, not of its behaviour --
# the kind a mutation cannot usefully test because no single edit reproduces the
# failure, and the kind that quietly decays as a file grows. So they are scanned
# for directly.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_setup

# =============================================================================
# The LG service channel is reachable from exactly one place
# =============================================================================

it "the string 'input-alt' appears in exactly one non-comment line"
# `input-alt` is what m1ddc calls I2C source 0x50, LG's service channel.
# Sweeping that channel has bricked LG monitors. If it appears anywhere but
# inside ddc_send there is a second way to reach it, and the vendor gate that
# lives in ddc_send is no longer a gate.
hits=$(grep -rn 'input-alt' "$MAC_DIR/lib" "$TK" | grep -vc '^[^:]*:[0-9]*: *#' || true)
assert_equal 1 "$hits" 'source 0x50 must have exactly one door'

it 'and that line is in ddc_send, the function holding the vendor check'
owner=$(grep -rln 'DDC_VENDOR_GSM' "$MAC_DIR/lib")
assert_equal "$MAC_DIR/lib/display.sh" "$owner"
gate=$(sed -n '/^ddc_send() {/,/^}/p' "$MAC_DIR/lib/display.sh")
assert_match "$gate" 'input-alt'      'the sidechannel lives here'
assert_match "$gate" 'DDC_VENDOR_GSM' 'and so does the check on it'

it 'no function takes the channel or a source byte as a parameter'
# The channel is chosen from the configured method inside ddc_send. A caller
# that could pass one in could aim the sidechannel at another vendor's panel.
assert_no_match "$(cat "$MAC_DIR"/lib/*.sh)" 'ddc_send_raw'
assert_no_match "$(cat "$MAC_DIR"/lib/*.sh)" '_source=$'

# =============================================================================
# Every function declares its scratch variables local
# =============================================================================

it 'every _-prefixed variable a function assigns is declared local in it'
# Shell variables are global unless declared local, so a callee's loop index
# silently overwrites its caller's. select_many's `_i` did exactly that to the
# monitor check's, which crashed on an unbound array subscript the first time a
# batch was narrowed -- a path no unit test had reached.
#
# No single mutation reproduces that: with the caller's locals in place a
# callee's missing ones are harmless, and vice versa. It is the CONVENTION that
# holds, so the convention is what gets checked.
#
# The rule: UPPERCASE names are deliberate globals, _lowercase names are
# scratch and must be local. A variable only READ is fine -- that is how a
# helper reads its caller's state, and bash's dynamic scoping makes it work.
missing=$(awk '
  /^[a-z_][A-Za-z0-9_]*\(\) \{$/ { fn = $0; sub(/\(\).*/, "", fn); delete loc; delete asg; n = 0; next }
  fn == "" { next }
  /^}$/ {
    for (v in asg) if (!(v in loc)) print FILENAME ":" fn ": " v
    fn = ""; next
  }
  {
    line = $0
    sub(/[ \t]*#.*$/, "", line)
    if (line ~ /^[ \t]*local /) {
      k = line; sub(/^[ \t]*local[ \t]*/, "", k)
      split(k, parts, /[ \t]+/)
      for (i in parts) if (parts[i] != "") loc[parts[i]] = 1
      next
    }
    # for _v in ...
    t = line
    while (match(t, /for[ \t]+_[A-Za-z0-9_]*[ \t]+in/)) {
      v = substr(t, RSTART, RLENGTH); sub(/^for[ \t]+/, "", v); sub(/[ \t]+in$/, "", v)
      asg[v] = 1; t = substr(t, RSTART + RLENGTH)
    }
    # read ... _a _b
    t = line
    if (match(t, /read([ \t]+-[A-Za-z]+)*[ \t]+_[A-Za-z0-9_ \t]*/)) {
      v = substr(t, RSTART, RLENGTH); sub(/^read([ \t]+-[A-Za-z]+)*[ \t]+/, "", v)
      split(v, rs, /[ \t]+/)
      for (i in rs) if (rs[i] ~ /^_/) asg[rs[i]] = 1
    }
    # _v= and _v[i]= and _v+=
    t = line
    while (match(t, /_[A-Za-z0-9_]*(\[[^]]*\])?\+?=/)) {
      pre = (RSTART > 1) ? substr(t, RSTART - 1, 1) : " "
      v = substr(t, RSTART, RLENGTH)
      sub(/(\[[^]]*\])?\+?=$/, "", v)
      if (pre != "$" && pre !~ /[A-Za-z0-9_]/) asg[v] = 1
      t = substr(t, RSTART + RLENGTH)
    }
  }
' "$MAC_DIR"/lib/*.sh)
assert_equal '' "$missing" "these are assigned but not local"

it 'the scan actually finds something when a local declaration is removed'
# A structural check that cannot fail is decoration. Prove it bites.
probe=$(mktemp "$FAKE_DIR/probe.XXXXXX")
cat >"$probe" <<'EOS'
demo() {
  local _kept
  _kept=1
  _leaked=2
  printf '%s%s\n' "$_kept" "$_leaked"
}
EOS
found=$(awk '
  /^[a-z_][A-Za-z0-9_]*\(\) \{$/ { fn = $0; sub(/\(\).*/, "", fn); delete loc; delete asg; next }
  fn == "" { next }
  /^}$/ { for (v in asg) if (!(v in loc)) print fn ": " v; fn = ""; next }
  {
    line = $0; sub(/[ \t]*#.*$/, "", line)
    if (line ~ /^[ \t]*local /) {
      k = line; sub(/^[ \t]*local[ \t]*/, "", k); split(k, parts, /[ \t]+/)
      for (i in parts) if (parts[i] != "") loc[parts[i]] = 1
      next
    }
    t = line
    while (match(t, /_[A-Za-z0-9_]*(\[[^]]*\])?\+?=/)) {
      pre = (RSTART > 1) ? substr(t, RSTART - 1, 1) : " "
      v = substr(t, RSTART, RLENGTH); sub(/(\[[^]]*\])?\+?=$/, "", v)
      if (pre != "$" && pre !~ /[A-Za-z0-9_]/) asg[v] = 1
      t = substr(t, RSTART + RLENGTH)
    }
  }
' "$probe")
assert_equal 'demo: _leaked' "$found"

# =============================================================================
# The instruction files fit the tools that load them
# =============================================================================
#
# Codex loads the AGENTS.md chain from the git root down to its working
# directory into ONE budget of project_doc_max_bytes (32768 by default) and
# truncates the rest silently, mid-line. Measured 2026-08-31; see
# docs/decisions/002-instruction-files-for-two-agents.md. This check is what
# turns "keep it short" from a hope into a failing test, for BOTH platforms'
# chains -- it is file sizes only, so it runs here even for the chain this
# machine cannot otherwise test.

ROOT_DIR=$MAC_DIR/..
CODEX_BUDGET=32768
HEADROOM=2048
ROOT_CAP=20480
PLATFORM_CAP=10240

# Arithmetic expansion, because BSD wc pads its count with spaces.
root_bytes=$(( $(wc -c <"$ROOT_DIR/AGENTS.md") ))

it 'the root AGENTS.md stays short enough to be followed, not just loaded'
assert_true "$([ "$root_bytes" -le "$ROOT_CAP" ] && echo 0 || echo 1)" \
  "AGENTS.md is $root_bytes bytes; the cap is $ROOT_CAP. Move evidence to docs/measurements.md or a platform AGENTS.md rather than raising this."

for platform in macos windows; do
  it "AGENTS.md plus $platform/AGENTS.md fits under the Codex budget"
  plat_bytes=$(( $(wc -c <"$ROOT_DIR/$platform/AGENTS.md") ))
  chain=$(( root_bytes + plat_bytes ))
  assert_true "$([ "$plat_bytes" -le "$PLATFORM_CAP" ] && echo 0 || echo 1)" \
    "$platform/AGENTS.md is $plat_bytes bytes; the cap is $PLATFORM_CAP"
  assert_true "$([ "$chain" -le $(( CODEX_BUDGET - HEADROOM )) ] && echo 0 || echo 1)" \
    "AGENTS.md ($root_bytes) + $platform/AGENTS.md ($plat_bytes) = $chain bytes; Codex loads at most $CODEX_BUDGET and drops the rest without a word"
done

it 'every CLAUDE.md is an import of the AGENTS.md beside it, never a second copy'
# Claude Code reads CLAUDE.md, not AGENTS.md; the @ import is how it gets the
# same instructions. Anything else at the top of a CLAUDE.md is a second copy
# waiting to drift.
for f in "$ROOT_DIR/CLAUDE.md" "$ROOT_DIR/macos/CLAUDE.md" "$ROOT_DIR/windows/CLAUDE.md"; do
  first=$(grep -m1 -v '^[[:space:]]*$' "$f")
  assert_equal '@AGENTS.md' "$first" "$f must begin with @AGENTS.md"
done

finish
