#!/usr/bin/env bash
# Fails if a lean consumer resolves any dependency the traits should prune.
set -euo pipefail
cd "$(dirname "$0")/lean-consumer"
rm -f Package.resolved
# `swift build` alone will not rewrite Package.resolved when .build already
# holds resolution state, which would leave nothing for the check to read.
swift package resolve
swift build
# A missing Package.resolved means the build never resolved anything, and a
# check that cannot tell "clean" from "did not run" is worse than no check.
if [ ! -f Package.resolved ]; then
  echo "::error::no Package.resolved after building the lean consumer"
  exit 1
fi

forbidden=(hummingbird jwt-kit async-http-client swift-certificates swift-nio-ssl)
status=0
for pkg in "${forbidden[@]}"; do
  if grep -q "\"identity\" : \"$pkg\"" Package.resolved; then
    echo "::error::lean consumer resolved '$pkg' — trait gating has regressed"
    status=1
  fi
done
# Assert the count, do not merely print it. The README quotes this number, and
# a figure nothing checks is a figure that drifts: it read "8" against an
# actual 7 until the 2026-09-17 audit caught it. Update both together.
# 7 again from 0.35.0: 0.34 made it 8 with an ungated FlightTelemetry. That
# core now lives in swift-telemetry, and every use of it is trait-gated, so
# a lean consumer resolves neither it nor swift-service-context (D44).
resolved=$(grep -c '"identity"' Package.resolved)
expected=7
echo "lean consumer resolved $resolved packages"
if [ "$resolved" -ne "$expected" ]; then
  echo "::error::lean consumer resolves $resolved packages, expected $expected."
  echo "::error::If this is intended, update README.md's trait table and this script together."
  status=1
fi
[ $status -eq 0 ] && echo "no gated dependency leaked"
exit $status
