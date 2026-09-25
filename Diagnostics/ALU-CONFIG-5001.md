# ALU-CONFIG-5001: @ConfigValue without a literal key

**Severity:** error

## Meaning

A `@ConfigValue` has no key, or its key is not a string literal.

## Why Alula rejects it

The key is what the value is read from, and the build checks keys against
your configuration files. A missing or computed key cannot be checked.

## Fixes

1. Give the key as a string literal: `@ConfigValue("server.port")`.
2. For many related values, use a `@Settings` type with a namespace.

## Example

```swift
@ConfigValue("mail.from") var from: String
```

## Related

ALU-CONFIG-5002.
