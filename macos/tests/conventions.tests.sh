#!/bin/bash
# shellcheck disable=SC2016  # the scans below grep for LITERAL $TK_LAUNCHCTL
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

# The scan, as a function, so it can be pointed at a throwaway file and shown to
# work. ../AGENTS.md hard rule 5 asks BOTH suites to assert this self-testedly;
# Windows landed its half in commit 980ce3b, and this is the other.
alt_doors() {
  grep -rn 'input-alt' "$@" | grep -vc '^[^:]*:[0-9]*: *#' || true
}

it "the string 'input-alt' appears in exactly one non-comment line"
# `input-alt` is what m1ddc calls I2C source 0x50, LG's service channel.
# Sweeping that channel has bricked LG monitors. If it appears anywhere but
# inside ddc_send there is a second way to reach it, and the vendor gate that
# lives in ddc_send is no longer a gate.
hits=$(alt_doors "$MAC_DIR/lib" "$TK")
assert_equal 1 "$hits" 'source 0x50 must have exactly one door'

it 'and the scan that says so can count a second door, and ignores a comment'
# Without this the assertion above passes for as long as the string is spelled
# the way the grep expects, and stops meaning anything the moment it is not.
probe=$(mktemp "$FAKE_DIR/probe.XXXXXX")
printf '%s\n' \
  'ddc_send() { m1ddc set input-alt "$v"; }' \
  '# input-alt in a comment is documentation, not a door' \
  '  # and so is an indented one' >"$probe"
assert_equal 1 "$(alt_doors "$probe")" 'a commented mention is not a door'
printf '%s\n' 'sneak() { m1ddc set input-alt 0xF4; }' >>"$probe"
assert_equal 2 "$(alt_doors "$probe")" 'a second emitter must be counted'

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

# -----------------------------------------------------------------------------
# ...and the same, for C, where the source byte is a NUMBER
# -----------------------------------------------------------------------------
# The scan above keys on the string `input-alt`, which is m1ddc's spelling of
# source 0x50. C code emitting that source writes the byte numerically and
# contains no such string, so the shell scan would count one door and pass while
# a second existed. Hard rule 5 asks the suite to assert the gate is the only
# door; without this, that assertion silently stops covering half the tree.

alt_doors_c() {
  grep -rn '0x50' "$@" 2>/dev/null | grep -vc '^[^:]*:[0-9]*: *//' || true
}

it 'the byte 0x50 appears in exactly one non-comment line of C'
hits=$(alt_doors_c "$MAC_DIR"/*.c)
assert_equal 1 "$hits" 'the numeric service channel must have exactly one door too'

it 'and that C scan can count a second door, and ignores a comment'
# Same self-test as the shell scan above, for the same reason: without it this
# passes for exactly as long as the formatting happens to suit the grep.
probe_c=$(mktemp "$FAKE_DIR/probe.XXXXXX").c
printf '%s\n' \
  'uint8_t send[7] = { 0x50, 0x84, 0x03, 0xF4, 0x00, value, 0 };' \
  '// 0x50 in a comment is documentation, not a door' \
  '    // and so is an indented one' >"$probe_c"
assert_equal 1 "$(alt_doors_c "$probe_c")" 'a commented mention is not a door'
printf '%s\n' 'uint8_t sneak[2] = { 0x50, 0xF4 };' >>"$probe_c"
assert_equal 2 "$(alt_doors_c "$probe_c")" 'a second emitter must be counted'

it 'and the C door sits in the function holding the GSM vendor check'
# The emitter and the refusal must be the same function. If they drift apart the
# byte can be sent to a panel whose vendor was never checked.
owner_c=$(grep -rln 'DDC_VENDOR_GSM' "$MAC_DIR"/*.c)
assert_equal "$MAC_DIR/intel-ddc-probe.c" "$owner_c"
gate_c=$(sed -n '/^static bool i2c_set_lg_input_alt/,/^}/p' "$MAC_DIR/intel-ddc-probe.c")
assert_match "$gate_c" '0x50' 'the sidechannel byte lives here'
# The COMPARISON, not the name. DDC_VENDOR_GSM also appears in this function's
# refusal message, so matching the bare name passes even when the guard has been
# replaced by `if (0)` -- present but unreachable, which is the thing a
# structural check exists to catch and which this test did not catch until it
# was mutated and shown not to.
assert_match "$gate_c" 'vendor_id != DDC_VENDOR_GSM' 'and the guard on it is a real comparison'

# =============================================================================
# launchd is reached through exactly one name
# =============================================================================

it 'every launchctl invocation goes through "$TK_LAUNCHCTL"'
# The suite points $TK_LAUNCHCTL at a recorder. A bare `launchctl` anywhere in
# the program is a call the recorder cannot intercept -- and the last one ran
# `bootout gui/<uid>/<label>` against the developer's live watcher from every
# scripted configure that reached Save, with the suite green throughout.
# /dev/null forces the file:line: prefix even for one file, which the filters rely on.
bare=$(grep -n 'launchctl' "$MAC_DIR"/lib/*.sh "$TK" "$MAC_DIR/install.sh" /dev/null \
       | grep -v '^[^:]*:[0-9]*: *#' | grep -v '"\$TK_LAUNCHCTL"' \
       | grep -v '^[^:]*:[0-9]*:TK_LAUNCHCTL=' || true)
assert_equal '' "$bare" 'these lines reach launchd without going through $TK_LAUNCHCTL'

# =============================================================================
# A bootstrap is CAUGHT, never thrown -- and only one function may run one
# =============================================================================
#
# The bootout runs before the bootstrap, so between them nothing is watching.
# Every caller runs under `set -euo pipefail`: an unchecked `bootstrap` aborted
# inside that window, leaving the daemon installed, the agent booted out and
# `status` still reporting "at boot" off the plist on disk. The other shape was
# `|| true` followed by an unconditional "restarted".
#
# Structural, for the reason Windows gives for the same check (commit 9cfa9e0):
# reaching it for real means loading a job into launchd, which outlives
# anything a suite can sandbox.

# Every `launchctl bootstrap` in <file> that is not inside tk_bootstrap itself.
bootstrap_doors() {
  local _f _body _line _text
  _f=$1
  _body=$(sed -n '/^tk_bootstrap() {/,/^}/p' "$_f")
  # `|| true`: most files contain no bootstrap at all, and under pipefail an
  # empty grep would abort the caller rather than report "no doors here".
  grep -n 'bootstrap' "$_f" /dev/null \
    | grep -v '^[^:]*:[0-9]*: *#' \
    | grep '\$TK_LAUNCHCTL" bootstrap' \
    | while IFS= read -r _line; do
        _text=${_line#*:*:}
        case $_body in
          *"$_text"*) ;;
          *) printf '%s\n' "$_line" ;;
        esac
      done || true
}

it 'only tk_bootstrap runs launchctl bootstrap'
doors=''
for f in "$MAC_DIR"/lib/*.sh "$TK" "$MAC_DIR/install.sh"; do
  doors="$doors$(bootstrap_doors "$f")"
done
assert_equal '' "$doors" 'these load launchd directly, so their failure is not caught'

it 'and tk_bootstrap really is a door, so the check above cannot pass vacuously'
# If the function were renamed or emptied, bootstrap_doors would find nothing to
# complain about and every assertion here would go quiet.
gate=$(sed -n '/^tk_bootstrap() {/,/^}/p' "$MAC_DIR/lib/manage.sh")
assert_match "$gate" 'bootstrap system'   'the elevated load lives here'
assert_match "$gate" 'TK_BOOTSTRAP_ERR'   'and it keeps the reason for the caller'
# The BOOTOUT is `|| true` on purpose -- it fails when nothing is loaded, which
# is the ordinary first-install case. The bootstrap is the one whose answer
# means something, so only its lines are checked.
swallowed=$(printf '%s\n' "$gate" | grep 'bootstrap' | grep '|| true' || true)
assert_equal '' "$swallowed" 'the bootstrap itself may not be swallowed'

it 'and the check can SEE an unguarded bootstrap, and does not fire on a guarded one'
probe=$(mktemp "$FAKE_DIR/probe.XXXXXX")
cat >"$probe" <<'EOS'
tk_bootstrap() {
  "$TK_LAUNCHCTL" bootstrap "$_domain" "$_plist"
}
cmd_restart() {
  "$TK_LAUNCHCTL" bootstrap gui/501 "$TK_PLIST" || true   # a second door
}
# "$TK_LAUNCHCTL" bootstrap in a comment is fine
EOS
found=$(bootstrap_doors "$probe")
assert_match "$found" 'a second door' 'an unguarded bootstrap must be reported'
assert_equal 1 "$(printf '%s\n' "$found" | grep -c .)" \
  "only the unguarded one may be reported, got: $found"

it 'every caller of tk_bootstrap acts on its answer'
# Calling it and ignoring the result reinstates exactly the bug: the failure is
# caught and then thrown away. Each call must be a condition or be negated.
loose=$(grep -n 'tk_bootstrap ' "$MAC_DIR"/lib/*.sh "$TK" "$MAC_DIR/install.sh" /dev/null \
        | grep -v '^[^:]*:[0-9]*: *#' \
        | grep -v 'if ! tk_bootstrap' | grep -v 'elif tk_bootstrap' || true)
assert_equal '' "$loose" 'these call tk_bootstrap without acting on whether it worked'

it 'and TK_LAUNCHCTL is defined once, in common.sh, and is overridable'
defs=$(grep -ln '^TK_LAUNCHCTL=' "$MAC_DIR"/lib/*.sh "$TK" "$MAC_DIR/install.sh" || true)
assert_equal "$MAC_DIR/lib/common.sh" "$defs"
assert_match "$(grep '^TK_LAUNCHCTL=' "$MAC_DIR/lib/common.sh")" '${TK_LAUNCHCTL:-' \
  'the suite must be able to override it'

it 'the launchctl scan actually finds a bare call'
probe=$(mktemp "$FAKE_DIR/probe.XXXXXX")
printf '%s\n' 'x() {' '  "$TK_LAUNCHCTL" print a' '  launchctl bootout b   # bad' '  # launchctl in a comment is fine' 'TK_LAUNCHCTL=${TK_LAUNCHCTL:-/bin/launchctl}' '}' >"$probe"
found=$(grep -n 'launchctl' "$probe" /dev/null | grep -v '^[^:]*:[0-9]*: *#' | grep -v '"\$TK_LAUNCHCTL"' \
        | grep -v '^[^:]*:[0-9]*:TK_LAUNCHCTL=' || true)
assert_no_match "$found" 'TK_LAUNCHCTL='
assert_match "$found" 'launchctl bootout b'
assert_no_match "$found" 'print a'
assert_no_match "$found" 'in a comment'

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

# =============================================================================
# A test that did not run is never reported as one that passed
# =============================================================================
#
# run.sh captures each file's output and prints it only on FAIL, so a skip
# written to stderr was swallowed and the file's exit 0 counted as a PASS. On a
# machine without python3 that hid every pty-driven menu test while the run said
# "all 11 test files passed". Windows had the identical shape (commit 5febeec).
#
# Driven end to end, against throwaway probes in a COPY of the harness: the
# rendering was the bug, so asserting the helpers alone would not have caught
# it. The copy is why no probe file is ever left in the real tests directory,
# where the next run would pick it up.

probe_dir=$(mktemp -d "$FAKE_DIR/harness.XXXXXX")
cp "$TESTS_DIR/run.sh" "$TESTS_DIR/lib.sh" "$probe_dir/"

cat >"$probe_dir/pass.tests.sh" <<'EOS'
#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
it 'runs'; assert_equal a a
finish
EOS
cat >"$probe_dir/filelevel.tests.sh" <<'EOS'
#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
exit_skipped 'PROBE-WHOLE-FILE'
EOS
cat >"$probe_dir/caselevel.tests.sh" <<'EOS'
#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
it 'one that runs'; assert_equal a a
it 'one that cannot'; skip_case 'PROBE-ONE-CASE'
finish
EOS

set +e
probe_out=$(bash "$probe_dir/run.sh" --no-lint 2>&1); probe_rc=$?
set -e

it 'a file that could not run reports SKIP, with its reason, and never PASS'
assert_match "$probe_out" 'SKIP  filelevel.tests.sh'
assert_match "$probe_out" 'PROBE-WHOLE-FILE' 'the reason must be printed every time'
assert_no_match "$probe_out" 'PASS  filelevel.tests.sh'

it 'and is named in the summary as having proved nothing'
assert_match "$probe_out" 'did NOT run on this machine and proved nothing'

it 'a skipped case is surfaced even though its file PASSED'
# The swallowing bug in one line: this file exits 0, so its output was hidden.
assert_match "$probe_out" 'PASS  caselevel.tests.sh'
assert_match "$probe_out" 'PROBE-ONE-CASE'
assert_match "$probe_out" '1 case(s) inside the files that did run were skipped'

it 'a skip does not raise the exit code -- it is a fact about the machine'
assert_equal 0 "$probe_rc"

it 'and the count of files that passed excludes the one that did not run'
# Three probe files, one skipped: saying "all 3 passed" is the false claim.
assert_match "$probe_out" 'all 2 test files passed'

it 'the probe harness can still go red, so the assertions above are not vacuous'
cat >"$probe_dir/red.tests.sh" <<'EOS'
#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
it 'fails'; assert_equal a b
finish
EOS
set +e
red_out=$(bash "$probe_dir/run.sh" --no-lint red 2>&1); red_rc=$?
set -e
assert_match "$red_out" 'FAIL  red.tests.sh'
assert_equal 1 "$red_rc"

it 'every test file ends in finish, or its skipped-case tally never prints'
# skip_case tallies into a counter that only `finish` reports. A file that
# exits by another route drops the count silently -- the same class of bug.
for f in "$TESTS_DIR"/*.tests.sh; do
  last=$(grep -v '^[[:space:]]*$' "$f" | tail -1)
  assert_equal 'finish' "$last" "$(basename "$f") must end in finish"
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
