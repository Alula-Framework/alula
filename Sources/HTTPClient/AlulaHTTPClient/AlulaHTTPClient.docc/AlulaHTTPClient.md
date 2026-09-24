# ``AlulaHTTPClient``

Calling other services: a timeout on every attempt, retries only where
repeating is safe, trace context carried across, and a cap on what is read.

## Overview

List ``AlulaHTTPClientModule`` and inject the client:

```swift
@Service struct Weather {
    @Inject var http: OutboundHTTPClient

    func forecast(for city: String) async throws -> Forecast {
        try await http.get(URL(string: "https://api.example.com/forecast?city=\(city)")!)
            .decode(Forecast.self)
    }
}
```

A non-2xx status is a response, not an error. `decode` is where success is
demanded.

## Retries

Only idempotent requests are retried: `GET`, `HEAD`, `OPTIONS`, `PUT` and
`DELETE`, or any request with an `Idempotency-Key` header. They are retried
on a connection failure, a timeout, or a 429/502/503/504, up to
`http-client.max-attempts` (3), with jittered exponential backoff. A
`Retry-After` of up to ten seconds is honoured. A longer one returns the
response as it is, rather than hold a request open for a minute.

## Tracing

Each request is a client span, child of whatever span is current (the server
span, inside a request). The application's instrument injects the span's
context into the outgoing headers, so a W3C `traceparent` reaches the next
service. The span records the URL without its query string, because query
strings carry tokens.

## Topics

- ``OutboundHTTPClient``
- ``OutboundRequest``
- ``OutboundResponse``
- ``OutboundHTTPPolicy``
- ``OutboundHTTPError``
- ``OutboundHTTPTransport``
- ``AsyncHTTPTransport``
- ``AlulaHTTPClientModule``
- ``OutboundHTTPConfigurationError``
