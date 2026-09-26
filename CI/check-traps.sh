#!/usr/bin/env bash
#
# Alula must not crash on anything it did not write itself.
#
# A trap in framework code turns a bad request, a typo in alula.yaml or a
# database going away into SIGILL and a backtrace — the least useful report
# there is, and in a server, an outage. So every place Alula code can trap
# on purpose (fatalError, precondition, preconditionFailure, try!, as!,
# .first!/.last!) is listed in CI/trap-allowlist.txt with the reason it can
# only be reached by a programming error, never by input, configuration or
# the state of a dependency. A new one fails this check until it is either
# turned into a thrown error or listed with its reason.
#
# What a grep cannot see — arithmetic overflow, an index out of range, a
# force-unwrap of a parsed value — is covered by the fuzz suites
# (ParserFuzzTests, GossipFuzzTests). Both are needed.
#
# Also refused: framework code calling Configuration.get(_:default:), which
# traps on a malformed value. An operator's typo must reach the coded
# configuration error at startup, not a crash.
#
# Macro implementations and the registration generator are excluded: they
# run inside the compiler, where a trap fails the build, not the
# application.
#
# Allowlist format, one site per line, tab-separated:
#   <path>	<the line, trimmed>	<why only a programming error reaches it>
# Keyed on the line's text, not its number, so unrelated edits do not churn
# it. Update an entry when you change the line.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='fatalError\(|preconditionFailure\(|precondition\(|try!|as! |\.first!|\.last!'
excluded='/(AlulaCoreMacrosImpl|AlulaWebMacrosImpl|alula-registration-gen|AlulaRouteScan|[A-Za-z]*MacrosImpl)/'

current=$(mktemp)
allowed=$(mktemp)
trap 'rm -f "$current" "$allowed"' EXIT

grep -rnE "$pattern" Sources --include='*.swift' \
  | grep -vE "$excluded" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1\t\2/' \
  | LC_ALL=C sort > "$current"

grep -vE '^[[:space:]]*(#|$)' CI/trap-allowlist.txt \
  | awk -F'\t' '{ if (NF < 3 || $3 == "") { print "trap-allowlist.txt: entry without a reason: " $0 > "/dev/stderr"; bad = 1 } print $1 "\t" $2 } END { exit bad }' \
  | LC_ALL=C sort > "$allowed"

status=0
new=$(LC_ALL=C comm -23 "$current" "$allowed")
if [ -n "$new" ]; then
  echo "New trap sites in framework code. Throw an error instead, or list each in"
  echo "CI/trap-allowlist.txt with why only a programming error can reach it:"
  echo "$new" | sed 's/^/  /'
  status=1
fi
stale=$(LC_ALL=C comm -13 "$current" "$allowed")
if [ -n "$stale" ]; then
  echo "Allowlisted trap sites that no longer exist (remove them, or update the line):"
  echo "$stale" | sed 's/^/  /'
  status=1
fi

defaults=$(grep -rnE '\.get\("[^"]+", default:' Sources --include='*.swift' \
  | grep -vE "$excluded" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$defaults" ]; then
  echo "Framework code calls Configuration.get(_:default:), which traps on a malformed"
  echo "value. Use getIfPresent(_:as:) and let the error reach the startup report:"
  echo "$defaults" | sed 's/^/  /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "trap check: $(wc -l < "$current" | tr -d ' ') sites, each allowlisted with a reason"
fi
exit "$status"
