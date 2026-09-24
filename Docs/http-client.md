# Alula HTTP Client

Calling other services. Every attempt has a timeout. Retries happen only
where repeating a request is safe, trace context crosses into the next
service, and nothing reads an unbounded response into memory.

## Adding this module

| | |
|---|---|
| **Trait** | `HTTPClient` |
| **Products** | `AlulaHTTPClient`; `AlulaHTTPClientTesting` for tests |
| **Module** | `AlulaHTTPClientModule.self` |

```swift
.package(url: "https://github.com/Alula-Framework/alula.git",
         from: "0.40.0", traits: ["Web", "HTTPClient"]),
```

```yaml
http-client:
  timeout-seconds: 30        # per attempt, connect to last byte
  max-attempts: 3            # for retryable failures, the first included
  max-response-bytes: 10485760
```

## Using it

```swift
@Service struct Weather {
    @Inject var http: OutboundHTTPClient

    func forecast(for city: String) async throws -> Forecast {
        try await http.get(URL(string: "https://api.example.com/forecast?city=\(city)")!)
            .decode(Forecast.self)
    }
}
```

`send(_:)` takes an `OutboundRequest` (method, URL, headers, body, and an
optional per-request timeout). `get` and `post(_:json:)` are shorthands. A
404 or a 500 is a *response*. `decode` demands a 2xx, and throws
`unexpectedStatus` with the start of the body otherwise.

## When it retries

| | Retried? |
|---|---|
| `GET`, `HEAD`, `OPTIONS`, `PUT`, `DELETE` | yes |
| any request with an `Idempotency-Key` header | yes |
| `POST`, `PATCH` without one | **never** |

For those, it retries on a connection failure, a timeout, or a 429, 502, 503
or 504, with jittered exponential backoff from 200 ms. `Retry-After` is
honoured up to 10 seconds. A longer one returns the response as it is,
rather than hold a caller open for a minute. When attempts run out, the last
response is returned rather than an error, so a caller sees what the service
said.

A `POST` that failed after the server read it may already have taken
effect, so repeating it is the caller's decision to make, by sending an
`Idempotency-Key` the other service honours.

## Tracing

Each request is a client span, a child of the current span (the server
span, inside a request handler). The application's instrument injects the
span context into the outgoing headers, so W3C `traceparent` reaches the next
service and its server span joins the same trace. The span records method,
host, status and the URL **without its query string**, because query strings
carry tokens often enough that recording them is a leak.

## Testing

```swift
let stub = StubHTTPTransport(responses: [
    .init(status: .serviceUnavailable),
    .init(status: .ok, body: Data(#"{"high":21}"#.utf8)),
])
let weather = Weather(http: OutboundHTTPClient(transport: stub))
#expect(try await weather.forecast(for: "Oslo").high == 21)
#expect(stub.requests.count == 2)        // the retry is visible
```

## Not here yet

- **Circuit breaking.** Retries are bounded per call, but nothing stops
  calling a service that has been down for a minute.
- **Request-ID propagation.** Trace context crosses, `X-Request-ID` does not.
- **Alula's own callers** (APNs, OIDC, JWKS) still call AsyncHTTPClient
  directly, through their own narrower seams.
