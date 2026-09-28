# ``AlulaTesting``

Every Alula testing module, behind one import.

## Overview

```swift
// Package.swift
.testTarget(name: "AppTests", dependencies: [
    "App",
    .product(name: "AlulaTesting", package: "alula"),
])
```

```swift
import AlulaTesting
```

This module has no API of its own. It re-exports the testing modules the
package's enabled traits allow:

| Module | Brings | Trait |
|---|---|---|
| `AlulaWebTesting` | `TestClient`, `RequestContext.mock`, `InMemoryTransport` | `Web` |
| `AlulaChannelsTesting` | `InMemoryChannelTransport`, `ChannelWireClient` | `Web` |
| `AlulaSessionsTesting` | `RecordingSessionStore` | none |
| `AlulaRateLimitTesting` | `RecordingRateLimitStore` | none |
| `AlulaQueueTesting` | `QueueTestHarness` | none |
| `AlulaMailTesting` | `RecordingMailTransport` | none |
| `AlulaPubSubTesting` | `InMemoryCluster`, `RecordingAdapter` | none |
| `AlulaSchedulerTesting` | `TestSchedulerClock`, `StubJobCoordinator` | none |
| `AlulaHTTPClientTesting` | `StubHTTPTransport` | `HTTPClient` |
| `AlulaAPNSTesting` | `RecordingAPNSTransport` | `APNS` |

A module whose trait is off is left out, and so are its dependencies: a
package resolved with `traits: []` gets the six modules that need no trait
and nothing from the HTTP stack.

Each module is still its own product. List one directly when a build should
compile only what it uses.
