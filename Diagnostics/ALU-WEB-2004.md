# ALU-WEB-2004: A malformed route path

**Severity:** error

## Meaning

A route or controller path is not a valid Alula path. A path must:

- start with `/`;
- name every `:parameter` segment, and each only once;
- use `**` only as the last segment;
- contain no quote or backslash.

## Why Alula rejects it

The route table is built at compile time. A malformed path would either
never match or match something other than what it says.

## Fixes

1. Fix the path as the message says.
2. Percent-encode a quote or backslash that is genuinely part of the path.

## Example

```swift
@Controller("/users")          // not "users"
@GetRoute("/:id/files/**")     // ** last
```

## Related

ALU-WEB-2001, ALU-WEB-2005.
