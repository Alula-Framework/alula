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
describe it. Some routes legitimately answer with a redirect or a file; those
say so with a comment and the warning stays quiet.

## Fixes

1. Return the type the route sends: `-> Report` rather than `-> Response`.
2. For a redirect, a download or another deliberately untyped answer, put `// alula:undocumented-response` above the handler.

## Example

```swift
// alula:undocumented-response — a PDF download.
@GetRoute("/:id/pdf")
func pdf(_ context: RequestContext, id: String) async throws -> Response
```

## Related

ALU-OAPI-3001.
