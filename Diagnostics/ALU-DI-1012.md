# ALU-DI-1012: A component used from another module is not public

**Severity:** error

## Meaning

A `@Component` declared in one Swift module is part of a graph composed in
another, but the type is not `public`, so the generated composition cannot
name it.

## Fixes

Declare the component (and its initializer dependencies) `public`, or move
it into the module that composes it.
