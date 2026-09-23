# ``FlightTelemetryBridges``

Telemetry to swift-metrics, swift-distributed-tracing and swift-log, and the
module that wires them from configuration.

## Overview

``FlightTelemetryModule`` is already part of any application using
`FlightWebModule`, `FlightSessionsModule`, `FlightSecurityModule` or
`FlightAPNSModule`. It reports every module's contributed metrics once a
metrics backend is bootstrapped, and traces spans once a tracer is. Each
piece also works on its own:

```swift
let metrics = try SwiftMetricsReporter().attach(definitions)
let tracing = try Telemetry.observeSpans(prefix: "hangar", id: "tracing", TracingObserver())
let logs = try LogBridge(logger: Logger(label: "telemetry"))
    .log(prefix: "flight.sessions", level: .debug)
    .attach()
```

This target needs the `Telemetry` trait, which `Web` and `APNS` imply.

## Topics

### The module

- ``FlightTelemetryModule``
- ``TelemetrySettings``
- ``TelemetryConfigKey``
- ``TelemetryConfigurationError``

### Bridges

- ``SwiftMetricsReporter``
- ``TracingObserver``
- ``LogBridge``

### Slow consumers

- ``TelemetrySubscription``
- ``TelemetryStreamOverflow``
