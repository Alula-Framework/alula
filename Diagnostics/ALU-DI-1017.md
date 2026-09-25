# ALU-DI-1017: A stored property the generated initializer does not assign

**Severity:** error

## Meaning

A `@Component`, `@Controller` or `@Middleware` type has a stored property
that is neither `@Inject` nor `@ConfigValue` and has no default value.

## Why Alula rejects it

The macro generates the type's initializer, and that initializer assigns
only injected and configured properties. Any other stored property needs a
value of its own, or the type cannot be initialized.

## Common causes

- A dependency that was meant to be `@Inject`.
- Per-instance state added without a starting value.

## Fixes

1. Mark it `@Inject` if composition should supply it.
2. Give it a default value: `var retries = 3`.
3. Make it computed if it derives from other properties.

## Example

```swift
@Service
struct Reports {
    @Inject var store: ReportStore
    let pageSize = 50
}
```

## Related

ALU-DI-1016.
