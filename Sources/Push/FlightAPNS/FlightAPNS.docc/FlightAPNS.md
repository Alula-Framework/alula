# ``FlightAPNS``

Apple Push Notification service: one call, one delivery attempt, a typed
answer.

## Overview

``APNSClient`` sends an ``APNSNotification`` to a ``DeviceToken`` over
HTTP/2 with a provider token it mints and reuses underneath, and reads the
gateway's answer into an ``APNSReceipt`` or an ``APNSError``:

```swift
@Service
struct Notifier {
    @Inject var apns: APNSClient

    func remind(_ token: DeviceToken) async throws {
        do {
            _ = try await apns.send(.alert(title: "Standup", body: "in 5 minutes"), to: token)
        } catch let error as APNSError where error.deviceTokenIsInvalid {
            try await tokens.forget(token)      // Apple said so; sending again gets you throttled
        }
    }
}
```

``FlightAPNSModule`` reads `apns.*` — key id, team id, the `.p8` key, the
topic, the environment — and provides the client. A missing key or an
unparseable one fails composition.

What is deliberately absent: a queue, batching, and a retry policy beyond
the one the protocol asks for (a fresh provider token after
`ExpiredProviderToken`, once). Fan-out and backoff belong to the
application, which knows what the pushes are. ``APNSError/isRetryable``
says whether trying again could help; ``APNSError/deviceTokenIsInvalid``
says the token is dead.

`FlightAPNSTesting`'s `RecordingAPNSTransport` stands in for the gateway.

## Topics

### Sending

- ``APNSClient``
- ``APNSNotification``
- ``APS``
- ``DeviceToken``
- ``PushType``
- ``PushPriority``
- ``APNSReceipt``
- ``APNSError``

### Hosting

- ``FlightAPNSModule``
- ``APNSConfiguration``
- ``APNSEnvironment``
- ``APNSConfigKey``
- ``APNSConfigurationError``

### The network

- ``APNSTransport``
- ``AsyncHTTPAPNSTransport``
- ``APNSRequest``
- ``APNSRawResponse``
