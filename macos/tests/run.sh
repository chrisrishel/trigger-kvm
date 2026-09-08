#!/bin/bash
#
# Run every test in this directory.
#
#   ./run.sh                all of them
#   ./run.sh config         only files whose name contains "config"
#   ./run.sh --no-lint      skip shellcheck
#
# Each *.tests.sh runs in its own process: the tests define stubs with the same
# names as real functions, and sharing one shell would let those leak into each
# other.
#
# A file or a case that cannot run on this machine reports SKIP, LOUDLY, and is
# counted separately -- never as a pass. Output is captured and shown only on
# FAIL, so a skip used to be swallowed: on a machine without python3 the whole
# interactive half of the walkthrough went untested and this said "all 11 test
# files passed". Every `SKIPPED:` line is surfaced whatever the verdict.
#
# Exit code is the number of files that failed, so CI can just check it. A skip
# is a fact about the machine rather than a failure, so it does not raise it.

set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
MAC_DIR=$(dirname "$HERE")

FILTER=""
LINT=1
for a in "$@"; do
  case $a in
    --no-lint) LINT=0 ;;
    *)         FILTER=$a ;;
  esac
done

failed=0

# A .mutbak means an interrupted mutation run left a source file MUTATED. Testing
# that tree would measure the mutant and report whatever it happened to do, so
# stop loudly instead -- the failure mode this replaces is a green suite, or a
# baffling red one, against code nobody wrote.
strays=$(ls "$MAC_DIR"/*.mutbak "$MAC_DIR"/lib/*.mutbak "$MAC_DIR"/tests/*.mutbak \
            "$MAC_DIR"/../specs/*.mutbak 2>/dev/null || true)
if [ -n "$strays" ]; then
  echo "  FAIL  the source tree is MUTATED -- an interrupted mutation run left:"
  printf '%s\n' "$strays" | while IFS= read -r stray; do printf '        %s\n' "$stray"; done
  echo "        restore it with: bash tests/mutate.sh --restore-only"
  exit 1
fi

# Linting is the shell's answer to Set-StrictMode. The things shellcheck catches
# -- an unquoted expansion that word-splits, a variable that is never read, a
# `[ x && y ]` that is not what it looks like -- are exactly the ones that are
# quiet in a test run and terminal in front of a user. (This comment deliberately
# does not begin with the linter's own name: a comment that starts that way is
# read as a directive and fails to parse.)
if [ "$LINT" = "1" ]; then
  if command -v shellcheck >/dev/null 2>&1; then
    # -x so it follows the `. lib/...` sources. The libs are sourced, never run,
    # so shellcheck cannot infer their shell without being told.
    targets="$MAC_DIR/trigger-kvm"
    [ -f "$MAC_DIR/install.sh" ] && targets="$targets $MAC_DIR/install.sh"
    [ -f "$MAC_DIR/../specs/check-conformance.sh" ] &&
      targets="$targets $MAC_DIR/../specs/check-conformance.sh"
    # shellcheck disable=SC2086
    if shellcheck -x -P SCRIPTDIR -s bash $targets "$MAC_DIR"/lib/*.sh "$HERE"/*.sh 2>&1; then
      echo "  PASS  shellcheck"
    else
      echo "  FAIL  shellcheck"
      failed=$(( failed + 1 ))
    fi
  else
    echo "  SKIP  shellcheck (not installed: brew install shellcheck)"
  fi
fi

files=$(find "$HERE" -name '*.tests.sh' | sort)
if [ -n "$FILTER" ]; then
  files=$(printf '%s\n' "$files" | grep -- "$FILTER" || true)
fi
if [ -z "$files" ]; then
  echo "no test files match '$FILTER'"
  exit 1
fi

# Every line a file wrote that begins `SKIPPED:` -- printed whatever the verdict,
# because a file that passed everything it ran is still not a file that ran.
say_skips() { printf '%s\n' "$1" | grep '^SKIPPED:' | sed 's/^/        /' || true; }

n=0
skipped_files=""
skipped_cases=0
for f in $files; do
  n=$(( n + 1 ))
  base=$(basename "$f")
  # macOS has no timeout(1). A test that wedges -- a menu spinning on a key it
  # does not recognise, a watcher that never exits -- must fail loudly rather
  # than hang the run.
  out=$(bash "$f" 2>&1 & p=$!
        ( sleep "${TK_TEST_TIMEOUT:-240}"; kill -9 $p 2>/dev/null ) >/dev/null 2>&1 &
        w=$!; wait $p; rc=$?; kill $w 2>/dev/null; exit $rc)
  rc=$?
  # A case-level skip tallies inside the file, which then exits 0 or 1 as usual,
  # and `finish` prints the count. Read the count from there rather than
  # counting SKIPPED lines: exit_skipped writes one too, and one skipped case
  # writes two (its own line, and the tally).
  cases=$(printf '%s\n' "$out" | sed -n 's/^SKIPPED: \([0-9][0-9]*\) case(s).*/\1/p' | tail -1)
  [ -n "$cases" ] || cases=0
  skipped_cases=$(( skipped_cases + cases ))

  # exit_skipped is exit 2 WITH a SKIPPED: line; a bare exit 2 is a crash.
  [ "$rc" = 2 ] && ! printf '%s\n' "$out" | grep -q '^SKIPPED:' && rc=3
  case $rc in
    0) echo "  PASS  $base"
       say_skips "$out"
       [ -n "${TK_TEST_VERBOSE:-}" ] && printf '%s\n' "$out" ;;
    2) echo "  SKIP  $base"
       say_skips "$out"
       skipped_files="$skipped_files $base" ;;
    *) echo "  FAIL  $base"
       printf '%s\n' "$out"
       failed=$(( failed + 1 )) ;;
  esac
done

nskipped=$(printf '%s' "$skipped_files" | wc -w | tr -d ' ')
ran=$(( n - nskipped ))

echo
if [ "$failed" = "0" ]; then echo "all $ran test files passed"
else                          echo "$failed of $ran FAILED"; fi
if [ "$nskipped" != "0" ]; then
  echo "$nskipped did NOT run on this machine and proved nothing:$skipped_files"
fi
if [ "$skipped_cases" != "0" ]; then
  echo "$skipped_cases case(s) inside the files that did run were skipped -- see SKIPPED above"
fi
exit $failed
