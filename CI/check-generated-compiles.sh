#!/usr/bin/env bash
#
# Fails if the file flight-registration-gen emits does not compile.
#
# FlightRegistrationGenTests drives the real generator and asserts on its
# diagnostics and its output text — the right contract for a build tool, and
# the reason a non-compiling emission can pass every one of them. It did: the
# graph initializer emitted `x ?? (try C())`, which Swift rejects because `??`
# takes its right side as an autoclosure, and a test asserted that very
# spelling. Every application with a configuration-reading component failed to
# build while the suite stayed green.
#
# Type-checking the emission in-process would mean reconstructing SwiftPM's
# compile line by hand — 15+ -fmodule-map-file flags naming the dependency
# set, the arch triple and the build-system layout. That test would break on a
# dependency bump and get muted. Building a real consumer lets SwiftPM compute
# its own flags with whichever toolchain is in use, which is the same reason
# check-lean-consumer.sh builds one.
set -euo pipefail
cd "$(dirname "$0")/generated-consumer"

# Trust the exit code, not a grep for "Build complete" — run-tests.sh exists
# because grepping for an expected summary let 13 failing fixtures hide.
swift build --enable-all-traits

# A check that cannot tell "compiled" from "never ran" is worse than no check:
# a plugin that silently emitted nothing would sail through the build above.
generated=$(find .build/plugins/outputs -name 'FlightRegistration.generated.swift' 2>/dev/null | head -1)
if [ -z "$generated" ]; then
  echo "::error::no FlightRegistration.generated.swift was produced — the plugin did not run"
  exit 1
fi

# The throwing-node path is the one that shipped broken, so assert the fixture
# actually exercised it rather than trusting that it still has a @ConfigValue.
if ! grep -q 'try (' "$generated"; then
  echo "::error::the generated graph has no throwing initializer — the fixture no longer covers the path this check exists for"
  echo "  in: $generated"
  exit 1
fi

echo "generated file compiles ($(wc -l < "$generated") lines, throwing node present)"
