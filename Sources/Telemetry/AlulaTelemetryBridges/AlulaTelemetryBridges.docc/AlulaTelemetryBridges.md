# ``AlulaTelemetryBridges``

Telemetry to swift-metrics, swift-distributed-tracing and swift-log, and the
module that wires them from configuration.

## Overview

``AlulaTelemetryModule`` is already part of any application using
`AlulaWebModule`, `AlulaSessionsModule`, `AlulaSecurityModule` or
`AlulaAPNSModule`. It reports every module's contributed metrics once a
metrics backend is bootstrapped, and traces spans once a tracer is. Each
piece also works on its own:

```swift
let metrics = try SwiftMetricsReporter().attach(definitions)
let tracing = try Telemetry.observeSpans(prefix: "hangar", id: "tracing", TracingObserver())
let logs = try LogBridge(logger: Logger(label: "telemetry"))
    .log(prefix: "alula.sessions", level: .debug)
    .attach()
```

This target needs the `Telemetry` trait, which `Web` and `APNS` imply.

## Topics

### The module

- ``AlulaTelemetryModule``
- ``TelemetrySettings``
- ``TelemetryConfigKey``
- ``TelemetryConfigurationError``

### Bridges

- ``SwiftMetricsReporter``
- ``TracingObserver``
- ``LogBridge``
