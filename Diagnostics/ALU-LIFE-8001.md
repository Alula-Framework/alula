# ALU-LIFE-8001: Modules need each other in a cycle

**Severity:** error

## Meaning

Each module in a set needs, to be constructed, a value another in the set
holds: `RelayModule` needs the component graph, and the graph needs a value
`RelayModule` provides.

## Why Alula rejects it

Modules are constructed in dependency order. A cycle has no first member.

## Fixes

Move the shared value into a module both can take it from — often a small
module that only holds it.

## Related

ALU-DI-1003 (components in a cycle).
