# ALU-CMD-7001: Two modules declare one command name

**Severity:** error

## Meaning

Two modules both declare a `CommandRegistration` with the same name.

## Why Alula rejects it

Command names are one namespace across the application. Running whichever
module was listed first would let the order of `modules:` decide what
`swift run App <name>` does.

## Common causes

- Two modules that each ship a `migrate` or `seed` command.

## Fixes

1. Rename one of them — a module prefix works: `billing-seed`.

## Example

```swift
CommandRegistration("billing-seed", abstract: "Seed billing plans") { context in … }
```

## Related

ALU-CMD-7002.
