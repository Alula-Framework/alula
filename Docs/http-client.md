# Alula HTTP Client

Calling other services. Every attempt has a timeout. Retries happen only
where repeating a request is safe, trace context crosses into the next
service, and nothing reads an unbounded response into memory.

## Adding this module

| | |
|---|---|
| **Trait** | `HTTPClient` |
| **Products** | `AlulaHTTPClient`; `AlulaTesting` for tests (or `AlulaHTTPClientTesting` alone) |
| **Module** | `AlulaHTTPClientModule.self` |

```swift
.package(url: "https://github.com/Alula-Framework/alula.git",
         from: "0.62.0", traits: ["Web", "HTTPClient"]),
```

```yaml
http-client:
  timeout-seconds: 30        # per attempt, connect to response head
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

For those, it retries on a timeout, a failure to connect or a connection
that broke, or a 429, 502, 503 or 504, with jittered exponential backoff
from 200 ms. `Retry-After` is honoured up to 10 seconds. A longer one returns
the response as it is, rather than hold a caller open for a minute. When
attempts run out on one of those statuses, the last response is returned
rather than an error, so a caller sees what the service said. When they run
out on a timeout or a broken connection, the last error is thrown.

The timeout is per attempt, and it ends when the response head arrives:
the body is then read up to `max-response-bytes` under AsyncHTTPClient's own
idle read timeout, not this one. There is no budget across attempts, so a
call can take `max-attempts` timeouts plus the waits between them — unless
it runs inside a request with a deadline. There, each attempt's timeout
shrinks to the time left, no retry waits past it, and an attempt that would
start with nothing left throws `timedOut` without sending. A task cancelled
during a backoff wait ends with `CancellationError`, not another attempt.
[interactions.md](interactions.md#request-deadlines-and-outbound-retries)
has how that meets `web.request-timeout-seconds`.

A `POST` that failed after the server read it may already have taken
effect, so repeating it is the caller's decision to make, by sending an
`Idempotency-Key` the other service honours.

## Calling as a service account

`AlulaClientCredentialsModule` gets a service account's access tokens by the
OAuth 2.0 client credentials grant and sends them as a bearer token. List it
beside `AlulaHTTPClientModule`, whose `OutboundHTTPClient` it uses, and
configure `http-client.client-credentials.*`:

```yaml
http-client:
  client-credentials:
    issuer: https://id.example.com/realms/main   # or token-url, not both
    client-id: billing-worker
    client-secret: ${BILLING_CLIENT_SECRET}
    scope: invoices:write                        # optional
    audience: https://api.example.com            # optional
    client-authentication: basic                 # basic (default) | post
```

```swift
@Service struct Invoices {
    @Inject var core: AuthorizedHTTPClient

    func list() async throws -> [Invoice] {
        try await core.send(OutboundRequest(url: invoicesURL)).decode([Invoice].self)
    }
}
```

- With `issuer`, the token endpoint is discovered from
  `<issuer>/.well-known/openid-configuration`.
- `ClientCredentialsTokenSource` caches each token until 30 seconds before it
  expires (a minute, when the answer has no `expires_in`), and callers asking
  at once share one request.
- `AuthorizedHTTPClient` sends the token and, on a `401`, drops it, fetches
  another and tries once more. A second `401` is the answer.
- A refusal names the endpoint, the client and the server's reason —
  `the token endpoint https://id.example.com/token refused client
  'billing-worker' (401): invalid_client: Invalid client credentials` — never
  the secret. An authorization server that cannot be reached or answers 5xx
  is `TemporarilyUnavailable`, so a handler that lets it propagate answers
  `503`.

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
