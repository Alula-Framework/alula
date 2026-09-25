# ALU-DI-1018: @Component on something other than a struct or final class

**Severity:** error

## Meaning

`@Component`, `@Service` or `@Repository` is attached to a non-final class,
an enum, an actor, a protocol or an extension.

## Why Alula rejects it

The macro generates an initializer and a registration for the type. A
subclass could override what the registration relies on, and the other
declarations have no initializer for the macro to generate. A struct or a
`final class` is the shape composition can build.

## Common causes

- A class written without `final`.

## Fixes

1. Mark the class `final` (the build offers this as a fix-it).
2. Make it a struct.

## Example

```swift
@Service
final class Billing { … }
```

## Related

ALU-WEB-2003.
