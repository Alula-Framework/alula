# Telemetry

Libraries say what happened. Applications decide what it becomes.

Alula's subsystems emit typed events (a request was handled, a session
was created, a sign-in failed) through
[swift-telemetry](https://github.com/Alula-Framework/swift-telemetry), a
package of its own. A library can emit without depending on Alula, and
Alula is one application of it. This page covers what Alula adds: the
events its subsystems emit, reporting them to swift-metrics,
swift-distributed-tracing and swift-log, and the configuration that wires
it. Declaring events, spans, handlers, metric definitions, testing, and the
rules that keep telemetry observational only are in swift-telemetry's
README.

```swift
.product(name: "AlulaTelemetryBridges", package: "alula")      // trait "Telemetry"; Web and APNS imply it
.product(name: "TelemetryMacros", package: "swift-telemetry")    // your own events
.product(name: "TelemetryTesting", package: "swift-telemetry")   // capture in tests
```

Telemetry is **observational only**: removing every handler must not
change what an application does. An order being placed is a domain event,
not telemetry.

## If you're building an application

You may have nothing to do. `AlulaWebModule`, `AlulaSessionsModule`,
`AlulaSecurityModule` and `AlulaAPNSModule` depend on
`AlulaTelemetryModule`, so an application using any of them has it
already. What it does depends on what you've bootstrapped:

- **A metrics backend (`MetricsSystem.bootstrap`).** Every metric the
  application's modules contribute is reported to it: request counts and
  latency by route, sessions, sign-ins, pushes (the tables are below).
- **A tracer (`InstrumentationSystem.bootstrap`).** Telemetry spans become
  tracing spans.
- **Neither.** Nothing is attached, and nothing is paid.

`telemetry.*` overrides either decision; see [Configuration](#configuration).

**Bootstrap before `Alula.run`.** The decision is made at composition. A
backend bootstrapped later, say from another module's initializer, is still
found when the module's service starts, but events emitted between
composition and then are not reported. To choose the backend explicitly
rather than through the global, provide it from a module, and composition
passes it in:

```swift
struct MetricsModule: AlulaModule {
    let metricsFactory: any MetricsFactory = PrometheusMetricsFactory()
}
```

### What Alula reports

| Metric | Kind | Tags | From |
|---|---|---|---|
| `alula_http_requests` | counter | `method`, `route`, `status` | `HTTPEvents.RequestHandled` |
| `alula_http_request_duration` | timer (ms) | `method`, `route` | `HTTPEvents.RequestHandled` |
| `alula_sessions_created` | counter | | `SessionEvents.Created` |
| `alula_sessions_regenerated` | counter | | `SessionEvents.Regenerated` |
| `alula_sessions_store_failures` | counter | `operation` | `SessionEvents.StoreFailed` |
| `alula_sessions_revoked` | counter (sum) | | `SessionEvents.Revoked` |
| `alula_sessions_revocation_failures` | counter | | `SessionEvents.RevocationFailed` |
| `alula_sign_in_started` | counter | `provider` | `SignInEvents.Started` |
| `alula_sign_in_attempts` | counter | `provider`, `outcome` | `SignInEvents.Attempt` |
| `alula_sign_in_duration` | timer (ms) | `provider` | `SignInEvents.Attempt` |
| `alula_sign_in_password_rehashes` | counter | | `SignInEvents.PasswordRehashed` |
| `alula_sign_in_expired` | counter | | `SignInEvents.Expired` |
| `alula_one_time_tokens_issued` | counter | `purpose` | `SignInEvents.TokenIssued` |
| `alula_one_time_tokens_redeemed` | counter | `purpose`, `outcome` | `SignInEvents.TokenRedemption` |
| `alula_apns_sends` | counter | `outcome` | `APNSEvents.Send` |
| `alula_apns_send_duration` | timer (ms) | `outcome` | `APNSEvents.Send` |
| `alula_apns_provider_tokens_minted` | counter | | `APNSEvents.ProviderTokenMinted` |

The names from 0.33 haven't changed. Every tag is a closed set: a route
*pattern* (`/users/:id`, never the path), a method, an outcome. That keeps
the number of series fixed however much traffic there is. A request nothing
matched is tagged `unmatched`, so a scanner walking random paths adds one
series, not thousands.

`alula_http_request` is an event, not a span. The request's server span is
already a tracing span, and a second one would trace every request twice.

## Contributing metrics

A module contributes metrics by holding them. `AlulaTelemetryModule`
collects every included module's `[TelemetryMetric]`, the same way
composition collects routes and channels (D15). That's how Alula's own
modules declare theirs, and how yours, or a package Alula has never heard
of, declares its own:

```swift
struct AppModule: AlulaModule {
    let telemetryMetrics: [TelemetryMetric] = [
        .distribution(Checkout.Stop.self, \.duration, unit: .milliseconds, tags: \.method)
    ]
}
```

Two definitions with one name fail composition, naming both events.

## Reporting

`SwiftMetricsReporter` maps definitions onto swift-metrics:

| Definition | swift-metrics |
|---|---|
| counter | `Counter.increment()` |
| sum | `Counter.increment(by:)`, or `FloatingPointCounter` for fractional values |
| lastValue | `Gauge.record` |
| distribution of a `Duration` | `Timer.recordNanoseconds`, displayed in `unit` |
| distribution of a number | `Recorder(aggregate: true).record` |

It translates and never aggregates; the backend does that. For the same
reason it doesn't pass on `buckets:`: swift-metrics has no way to hand
histogram boundaries to a backend, which configures its own. The hint stays
on the definition for a reporter that can use it. **Cardinality is
capped**: each metric keeps at most 1,000 tag combinations
(`telemetry.metrics.cardinality-limit`). Past that, values are recorded
with every tag set to `_overflow`, and
`TelemetryCardinalityExceeded` is emitted once for the metric. Totals stay
right, and an unbounded label nobody meant cannot take the backend down.

## Tracing and logs

Tracing is on whenever a tracer is bootstrapped, and
`telemetry.tracing.prefix` narrows it. `TracingObserver` starts a
swift-distributed-tracing span at each telemetry span's start, named after
the event, of the event's `kind`, with the metadata as attributes. The
tracing span becomes the parent of everything inside the body. At stop, the
stop metadata is added as attributes; at exception, the error is recorded
and the status set to `.error`. swift-otel exports it unchanged. Outside the
module:

```swift
let token = try Telemetry.observeSpans(prefix: "hangar", id: "tracing", TracingObserver())
```

`LogBridge` turns events into log lines: the event name as the message,
and the fields as metadata. It checks the level before encoding anything.

```swift
let tokens = try LogBridge(logger: Logger(label: "telemetry"))
    .log(QuerySpan.Exception.self, level: .error)
    .log(prefix: "alula.sessions", level: .debug)
    .attach()
```

`Logger.MetadataProvider.telemetry` puts `telemetry.local_span_id` on every
log line written inside a span, including plain `logger.info` calls:

```swift
LoggingSystem.bootstrap(StreamLogHandler.standardOutput, metadataProvider: .telemetry)
```

The id is *local*: unique within one process, repeated across replicas. In
aggregated logs it means something only beside the instance that wrote it.
For trace-wide correlation, multiplex with your tracer's provider, which
carries the distributed trace and span ids:
`.multiplex([.telemetry, otelProvider])`.

A `SpanObserver` is the general form of the tracing bridge, for anything
that must carry state from a span's start to its end, or change the
context its body runs in.

## Testing

Alula's events are captured like any other:

```swift
let attempts = await TelemetryTest.capture(SignInEvents.Attempt.self) {
    _ = try? await authenticator.authenticate(identifier: "ada", password: "wrong", clientAddress: nil)
}
#expect(attempts.map(\.metadata.outcome) == ["invalid_credentials"])
```

A capture sees its own body's emits, including requests made through
`TestClient`, and no other test's. `TelemetryTest` is swift-telemetry's
`TelemetryTesting`, and its README has the rest.

## Configuration

| Key | Default | |
|---|---|---|
| `telemetry.metrics.enabled` | when a metrics backend is bootstrapped | report contributed metrics |
| `telemetry.metrics.cardinality-limit` | `1000` | tag combinations per metric |
| `telemetry.tracing.enabled` | when a tracer is bootstrapped | turn spans into tracing spans |
| `telemetry.tracing.prefix` | every span | only spans under this name |
| `telemetry.log.prefix` | off | log every event under this name |
| `telemetry.log.level` | `debug` | the level those lines use |

A bad value fails composition and names the key.

