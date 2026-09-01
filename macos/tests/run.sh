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
# Exit code is the number of files that failed, so CI can just check it.

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

n=0
for f in $files; do
  n=$(( n + 1 ))
  # macOS has no timeout(1). A test that wedges -- a menu spinning on a key it
  # does not recognise, a watcher that never exits -- must fail loudly rather
  # than hang the run.
  if out=$(bash "$f" 2>&1 & p=$!
           ( sleep "${TK_TEST_TIMEOUT:-240}"; kill -9 $p 2>/dev/null ) >/dev/null 2>&1 &
           w=$!; wait $p; rc=$?; kill $w 2>/dev/null; exit $rc); then
    echo "  PASS  $(basename "$f")"
    [ -n "${TK_TEST_VERBOSE:-}" ] && printf '%s\n' "$out"
  else
    echo "  FAIL  $(basename "$f")"
    printf '%s\n' "$out"
    failed=$(( failed + 1 ))
  fi
done

echo
if [ "$failed" = "0" ]; then echo "all $n test files passed"
else                          echo "$failed of $n FAILED"; fi
exit $failed
