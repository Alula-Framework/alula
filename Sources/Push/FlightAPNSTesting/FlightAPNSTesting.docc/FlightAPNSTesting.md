# ``FlightAPNSTesting``

The gateway, replaced by a recorder.

## Overview

``RecordingAPNSTransport`` records every request an `APNSClient` would have
sent and answers from a script, so a suite asserts on the headers, the
topic and the payload with no network and no Apple account:

```swift
let gateway = RecordingAPNSTransport()
let client = APNSClient(configuration: configuration, transport: gateway)

_ = try await client.send(.alert(body: "hi"), to: token)
#expect(gateway.sent.last?.header("apns-topic") == "com.example.app")
#expect((try gateway.lastPayload()["aps"] as? [String: Any])?["alert"] != nil)

gateway.refuse(status: 410, reason: "Unregistered", timestamp: .now)
await #expect(throws: APNSError.self) { try await client.send(.alert(body: "hi"), to: token) }
```

## Topics

- ``RecordingAPNSTransport``
