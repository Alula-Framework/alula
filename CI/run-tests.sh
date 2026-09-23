#!/usr/bin/env bash
#
# Runs the suite and fails on ANY failure, swift-testing or XCTest.
#
# `swift test` exits non-zero on either, but its output does not: swift-testing
# prints a "Test run with N tests" summary last, and XCTest prints "Executed N
# tests, with M failures" earlier. Grepping for the summary you expect is how a
# failing macro-fixture suite hides behind a green swift-testing line — which
# is exactly what happened to 13 fixtures here.
#
# So: trust the exit code, and report both dialects.
#
set -uo pipefail
cd "$(dirname "$0")/.."

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

swift test --enable-all-traits "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

echo ""
echo "── summary"
# Sum every bundle. `swift test` prints one "Test run with N tests" per test
# bundle, so `tail -1` reports whichever bundle happened to finish last: it
# printed 0 for hangar's 324-test run and 14 for an alula-data run of 434.
# This script exists so a number here cannot lie, and that number was lying.
swifttesting=$(grep -oE "Test run with [0-9]+ tests" "$log" \
  | grep -oE "[0-9]+" \
  | awk '{ total += $1; bundles++ } END { if (bundles) printf "%d tests across %d bundle(s)", total, bundles }')
if [ -n "$swifttesting" ]; then
  echo "  swift-testing: $swifttesting"
else
  echo "  swift-testing: no bundle reported a total"
fi

xctest=$(grep -oE "Executed [0-9]+ tests, with [0-9]+ failures" "$log" \
  | awk '{ t += $2; f += $5 } END { if (NR) printf "%d tests, %d failures across %d bundle(s)", t, f, NR }')
[ -n "$xctest" ] && echo "  XCTest:        $xctest"

if grep -qE "Executed [0-9]+ tests, with [1-9][0-9]* failures" "$log"; then
  echo "::error::XCTest reported failures — these do not appear in the swift-testing summary"
  status=1
fi

exit $status
