#!/usr/bin/env bash
#
# Fails if a consumer depending on Alula the ordinary way — a version
# requirement, every trait on — cannot resolve.
#
# check-lean-consumer.sh cannot catch this class of failure, and did not:
# its consumer takes Alula by *path*, and SwiftPM exempts path dependencies
# from the rule that broke 0.28.0 and 0.29.0 — a package resolved by version
# may not depend, even behind a trait, on one pinned by `revision:` or
# `branch:`. Every real application takes Alula by version, so the only
# honest reproduction is a real version requirement against a real tag (D37).
#
# The working tree — tracked and untracked-but-not-ignored files, so an
# uncommitted change is what gets checked — is copied into a throwaway git
# repository, tagged 999.0.0, and a generated consumer resolves it through
# `file://` with `from:`. Resolution is the step that failed; nothing is built.
#
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Copy the working tree, not HEAD, so the check sees what is about to be
# committed. `.build` and other ignored paths stay behind. `safe.directory`
# because CI runs this in a container as a different user from the one that
# owns the checkout, and git refuses to read such a repository otherwise.
mkdir -p "$scratch/alula"
(cd "$root" && git -c safe.directory='*' ls-files -co --exclude-standard -z) \
  | (cd "$root" && xargs -0 cp --parents -t "$scratch/alula")
(
  cd "$scratch/alula"
  git init -q
  git add -A
  git -c user.name=ci -c user.email=ci@localhost commit -qm snapshot
  git tag 999.0.0
)

# Every trait a consumer can name. `Security` implies `Web`; `Web` and `APNS`
# imply `Telemetry`, named anyway so dropping an implication cannot hide it.
mkdir -p "$scratch/consumer/Sources/Consumer"
cat > "$scratch/consumer/Package.swift" <<EOF
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "versioned-consumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "file://$scratch/alula", from: "999.0.0", traits: ["Security", "APNS", "Telemetry"])
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(name: "AlulaSecurityCore", package: "alula"),
                .product(name: "AlulaAPNS", package: "alula"),
            ])
    ]
)
EOF
echo 'print("resolved")' > "$scratch/consumer/Sources/Consumer/main.swift"

if ! (cd "$scratch/consumer" && swift package resolve) >"$scratch/resolve.log" 2>&1; then
  cat "$scratch/resolve.log"
  echo "::error::a consumer depending on Alula by version, with every trait on, cannot resolve."
  echo "::error::Check Package.swift for a revision:/branch: dependency — see D37 in DECISIONS.md."
  exit 1
fi
resolved=$(grep -c '"identity"' "$scratch/consumer/Package.resolved")
echo "versioned consumer resolved Alula 999.0.0 with every trait: $resolved packages"
