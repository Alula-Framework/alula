# ALU-DI-1001: No module provides a required type

**Severity:** error

## Meaning

Something in the application needs a value of a type — a component's
`@Inject`, a route handler's parameter, a module's initializer — and no
module in the application provides one.

## Why Alula rejects it

Alula builds the whole application at compile time. A module provides a
value by holding it as a stored property with a written type; the build
matches every need against those properties. If nothing matches, there is
nothing to pass, and the application cannot be assembled.

## Common causes

- The module that owns the value is not in `modules:` (or in the
  `dependencies` of a module that is).
- The module holds the value in a property with no written type —
  `let state = LabState()` — which the build cannot see. The diagnostic
  names such a property when it finds one.
- The value is a plain class or struct nobody constructs: it should be a
  `@Component`, or a module should create and hold it.

## Fixes

1. Add the providing module to `modules:`.
2. Write the property's type: `let state: LabState = LabState()`.
3. Make the type a `@Component`, or have a module construct and hold it.

## Example

```swift
struct LabModule: AlulaModule {
    let state = LabState()            // invisible to composition
}

struct LabModule: AlulaModule {
    let state: LabState = LabState()  // provided
}
```

## Related

ALU-DI-1002 (several providers), ALU-DI-1011 (property with no written type).
