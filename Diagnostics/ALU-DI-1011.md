# ALU-DI-1011: A module property has no written type

**Severity:** warning

## Meaning

A module holds a stored property whose type is only inferred —
`let state = LabState()` — so composition cannot offer it to anything that
needs a `LabState`.

## Why Alula warns

The build reads your source, not the type checker's results; a property's
type must be written for it to be matched against needs.

## Fixes

Write the type: `let state: LabState = LabState()`.

## Related

ALU-DI-1001 (which names such a property when it is the likely cause).
