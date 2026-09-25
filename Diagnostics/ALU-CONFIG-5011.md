# ALU-CONFIG-5011: Configuration refers to an unset environment variable

**Severity:** error

## Meaning

A configuration file uses `${VAR}` and `VAR` is not set in the environment.

## Why Alula rejects it

Loading fails rather than leaving the key to a lower layer: the alternative
is a production deployment quietly running on base-layer development values.

## Fixes

1. Set the variable.
2. Or give a fallback in the file: `${DB_URL:-postgres://localhost/app}`.

## Example

```swift
database:
  url: ${DATABASE_URL}
```

## Related

ALU-CONFIG-5004.
