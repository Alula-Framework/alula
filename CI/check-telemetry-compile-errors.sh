#!/usr/bin/env bash
#
# Fails unless every case in CI/telemetry-compile-errors/cases is refused by
# the compiler with the message its first line names — and the positive
# control, which is the same API used correctly, builds.
#
# Typed events promise refusals: a measurement that is not a number, a tag
# that is not a tag, a tag or a field from another event, a malformed name.
# Unit tests cannot hold a promise that something does not compile; a build
# can. Each case is built as the fixture target's only source.
set -euo pipefail
cd "$(dirname "$0")/telemetry-compile-errors"
status=0
ran=0
for case_file in cases/*.swift; do
  expect=$(head -1 "$case_file" | sed -n 's|^// expect: ||p')
  if [ -z "$expect" ]; then
    echo "::error::$case_file has no '// expect:' first line"
    status=1
    continue
  fi
  # Each case under its own name, as the target's only source. Reusing one
  # file name let an incremental build miss a swap made within a second of
  # the last build, and a refusal read as "compiled"; a changed source set
  # is re-planned every time.
  rm -f Sources/Probe/*.swift
  cp "$case_file" "Sources/Probe/$(basename "$case_file")"
  ran=$((ran + 1))
  if output=$(swift build 2>&1); then
    if [ "$expect" = "compiles" ]; then
      echo "ok: $case_file compiles"
    else
      echo "::error::$case_file compiled; it must be refused ($expect)"
      status=1
    fi
  else
    if [ "$expect" = "compiles" ]; then
      echo "::error::the positive control $case_file does not compile — every refusal is meaningless until it does"
      echo "$output" | grep -E "error:" | head -20
      status=1
    elif echo "$output" | grep -F -q -- "$expect"; then
      echo "ok: $case_file refused ($expect)"
    else
      echo "::error::$case_file was refused, but not for the reason it pins: no '$expect' in the errors"
      echo "$output" | grep -E "error:" | head -20
      status=1
    fi
  fi
done
rm -f Sources/Probe/*.swift
if [ "$ran" -lt 2 ]; then
  echo "::error::ran $ran cases; the fixture directory is not where this script expects it"
  status=1
fi
exit $status
