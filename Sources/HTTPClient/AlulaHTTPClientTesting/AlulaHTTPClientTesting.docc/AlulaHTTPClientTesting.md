# ``AlulaHTTPClientTesting``

Test code that calls other services, without a network.

## Overview

``StubHTTPTransport`` answers from a closure, or from a list of responses
where the last one repeats. It records every request, each retry included:

```swift
let stub = StubHTTPTransport(responses: [
    .init(status: .serviceUnavailable),
    .init(status: .ok, body: Data(#"{"high":21}"#.utf8)),
])
let weather = Weather(http: OutboundHTTPClient(transport: stub))
#expect(try await weather.forecast(for: "Oslo").high == 21)
#expect(stub.requests.count == 2)
```

## Topics

- ``StubHTTPTransport``
