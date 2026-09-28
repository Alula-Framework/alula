# ALU-OAPI-3002: A route's response cannot be described

**Severity:** warning

## Meaning

The application serves an OpenAPI document and a route handler returns
`Response`, which could carry anything, so the document can only say the
route responds.

This check is **off unless you turn it on**, because most handlers that return
`Response` do so to choose a status — a 201, a 409 — not to hide a body:

```yaml
openapi:
  warn-undocumented-responses: true
```

## Why Alula rejects it

A client generated from the document has nothing to decode the response
into. Returning the `Codable` type the route sends lets Alula encode it and
describe it.

A route that legitimately answers with a redirect or a file is reported too:
the document cannot describe it either, and the list is what the switch asks
for. There is no per-route opt-out; the switch is the control.

## Fixes

1. Return the type the route sends: `-> Report` rather than `-> Response`.
2. For a redirect or a download, leave it: the warning is an accurate entry
   in the list of routes the document describes only as "responds".

## Example

```swift
@GetRoute("/:id")
func show(_ context: RequestContext, id: String) async throws -> Report
```

## Related

ALU-OAPI-3001.
