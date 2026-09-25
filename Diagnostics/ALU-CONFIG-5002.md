# ALU-CONFIG-5002: @Settings declared in a way Alula cannot bind

**Severity:** error

## Meaning

A `@Settings` type has no literal namespace, or is not a struct or a final
class.

## Why Alula rejects it

`@Settings("auth")` binds every property under the `auth.` prefix. The
namespace has to be known at build time to check the keys, and the macro
needs a struct or final class to generate the initializer that binds them.

## Fixes

1. Give a namespace literal: `@Settings("auth")`.
2. Mark the class `final` (the build offers this as a fix-it), or make it a struct.

## Example

```swift
@Settings("auth")
struct AuthSettings {
    var sessionLifetime: Int = 3600
}
```

## Related

ALU-CONFIG-5001, ALU-CONFIG-5003.
