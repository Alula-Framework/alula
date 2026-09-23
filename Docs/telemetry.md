# Telemetry

Libraries say what happened. Applications decide what it becomes.

A library emits typed **events**: a session was created, a query finished,
a push was refused. It never picks a metrics backend or a log format, and
it never attaches anything. The application attaches **handlers**, and a
handler can turn an event into a counter, a histogram, a tracing span, a
log line, or an assertion in a test. Until something is attached, an emit
is one atomic load and a branch.

This is Elixir's `:telemetry`, typed. Events are Swift types, so a
measurement that isn't a number, a metric tag that isn't a tag, or a tag
taken from another event's fields fails to compile.

```swift
.product(name: "FlightTelemetry", package: "flight")          // emit, attach — no trait needed
.product(name: "FlightTelemetryTesting", package: "flight")   // capture in tests
.product(name: "FlightTelemetryBridges", package: "flight")   // swift-metrics, tracing, logs; trait "Telemetry"
```

`FlightTelemetry` depends on swift-service-context alone and needs no
trait, so any target can emit. The bridges need the `Telemetry` trait,
which `Web` and `APNS` turn on.

## If you're building an application

You may have nothing to do. `FlightWebModule`, `FlightSessionsModule`,
`FlightSecurityModule` and `FlightAPNSModule` depend on
`FlightTelemetryModule`, so an application using any of them has it
already. What it does depends on what you've bootstrapped:

- **A metrics backend (`MetricsSystem.bootstrap`).** Every metric the
  application's modules contribute is reported to it: request counts and
  latency by route, sessions, sign-ins, pushes (the tables are below).
- **A tracer (`InstrumentationSystem.bootstrap`).** Telemetry spans become
  tracing spans.
- **Neither.** Nothing is attached, and nothing is paid.

`telemetry.*` overrides either decision; see [Configuration](#configuration).

### What Flight reports

| Metric | Kind | Tags | From |
|---|---|---|---|
| `flight_http_requests` | counter | `method`, `route`, `status` | `HTTPEvents.RequestHandled` |
| `flight_http_request_duration` | timer (ms) | `method`, `route` | `HTTPEvents.RequestHandled` |
| `flight_sessions_created` | counter | | `SessionEvents.Created` |
| `flight_sessions_regenerated` | counter | | `SessionEvents.Regenerated` |
| `flight_sessions_store_failures` | counter | `operation` | `SessionEvents.StoreFailed` |
| `flight_sessions_revoked` | counter (sum) | | `SessionEvents.Revoked` |
| `flight_sessions_revocation_failures` | counter | | `SessionEvents.RevocationFailed` |
| `flight_sign_in_started` | counter | `provider` | `SignInEvents.Started` |
| `flight_sign_in_attempts` | counter | `provider`, `outcome` | `SignInEvents.Attempt` |
| `flight_sign_in_duration` | timer (ms) | `provider` | `SignInEvents.Attempt` |
| `flight_sign_in_password_rehashes` | counter | | `SignInEvents.PasswordRehashed` |
| `flight_sign_in_expired` | counter | | `SignInEvents.Expired` |
| `flight_one_time_tokens_issued` | counter | `purpose` | `SignInEvents.TokenIssued` |
| `flight_one_time_tokens_redeemed` | counter | `purpose`, `outcome` | `SignInEvents.TokenRedemption` |
| `flight_apns_sends` | counter | `outcome` | `APNSEvents.Send` |
| `flight_apns_send_duration` | timer (ms) | `outcome` | `APNSEvents.Send` |
| `flight_apns_provider_tokens_minted` | counter | | `APNSEvents.ProviderTokenMinted` |

The names from 0.33 haven't changed. Every tag is a closed set: a route
*pattern* (`/users/:id`, never the path), a method, an outcome. That keeps
the number of series fixed however much traffic there is. A request nothing
matched is tagged `unmatched`, so a scanner walking random paths adds one
series, not thousands.

`flight_http_request` is an event, not a span. The request's server span is
already a tracing span, and a second one would trace every request twice.

## Declaring an event

An event is a caseless enum, named for what happened:

```swift
@TelemetryEvent("hangar.query")
public enum Query {
    public struct Measurements {
        public var duration: Duration
        public var rows: Int
    }
    public struct Metadata {
        public var table: String
        public var statement: String? = nil   // opt-in, high-cardinality
    }
}
```

- **Measurements** are what metrics aggregate: integers, `Double`,
  `Duration`. A string measurement is a compile error at the property.
- **Metadata** is what they're sliced by. It holds any
  `TelemetryValue`: strings, `Bool`, numbers, `UUID`, optionals, and enums
  backed by a `String` or `Int`. An optional that's `nil` is left out
  entirely.
- **Either may be left out.** It's `NoFields` then. `@TelemetryEvent("flight.sessions.created") public enum Created {}`
  is a whole event.
- **Names** are dot-separated lowercase segments, `[a-z][a-z0-9_]*`, and
  are checked at build time. **Field names** are the property names,
  snake_cased: `errorType` is `error_type`, `requestURL` is `request_url`.
- **A public struct gets a public memberwise initializer**, because Swift
  synthesizes one only as `internal`.

Put a library's events in a public namespace (`SessionEvents.Created`,
`Hangar.Events.Query`) and document them. They're API, and follow semver
like any other. `@TelemetryFields` (metadata) and `@TelemetryMeasurements`
make a struct shared by several events encode itself. Every piece the
macros write can be written by hand; `Tests/Telemetry` has examples.

## Emitting

```swift
Telemetry.emit(Query.self) {
    (.init(duration: elapsed, rows: rows.count), .init(table: "users"))
}
Telemetry.emit(SessionEvents.Created.self)                            // nothing to carry
Telemetry.emit(SessionEvents.StoreFailed.self) { .init(operation: "save") }  // metadata only
Telemetry.emit(SessionEvents.Revoked.self) { .init(sessions: ended) }        // measurements only
```

The closure runs only if something will see the event. With nothing
attached there is no allocation, no lock and no task-local read, and the
payload is never built.

For a measurement taken *before* the emit point, typically a start time,
ask first so an unobserved operation doesn't read the clock either:

```swift
let start = Telemetry.isEnabled(Query.self) ? ContinuousClock.now : nil
let rows = try await run(sql)
Telemetry.emit(Query.self) {
    (.init(duration: start.map { .now - $0 } ?? .zero, rows: rows.count), .init(table: "users"))
}
```

## Spans

An operation with a duration is a span: it starts, then either stops or
throws.

```swift
@TelemetrySpan("hangar.query", kind: .client)
public enum QuerySpan {
    public struct Metadata { public var table: String }
    public struct StopMetadata { public var rows: Int = 0 }
}

let rows = try await Telemetry.span(QuerySpan.self, metadata: .init(table: "users")) { span in
    let rows = try await run(sql)
    span.stopMetadata.rows = rows.count
    return rows
}
```

The macro writes three phase events, and each is an ordinary event with
its own handlers:

| Phase | Measurements | Metadata |
|---|---|---|
| `QuerySpan.Start` (`hangar.query.start`) | `monotonicTime` | `table` |
| `QuerySpan.Stop` (`hangar.query.stop`) | `duration` | `table`, `rows` |
| `QuerySpan.Exception` (`hangar.query.exception`) | `duration` | `table`, `errorType`, `rows` |

`StopMetadata` is optional. It's what the body learns as it runs, and
every field needs a default, because a span that throws early reports the
defaults. The body's typed error passes through unchanged. The async form
takes `#isolation`, so the body needn't be `Sendable` and doesn't hop
executors.

**Unobserved, a span costs one load.** The body runs directly: no clock,
no metadata built, no context bound. Observed, the body runs in a child
`ServiceContext` carrying the span's id and its parent's, so every event
and span inside it, across child tasks too, knows where it came from.
`Task.detached` doesn't inherit it, as with swift-distributed-tracing.

`SpanHandle` is noncopyable, so it can't be kept past the body. The design
wanted it non-escapable as well; Swift 6.3 can't construct a `~Escapable`
value without an experimental feature (D42).

## Metrics

A metric is a definition, not a call. It says which event, which field,
and which tags, and a reporter turns it into a handler:

```swift
let metrics: [TelemetryMetric] = [
    .counter(QuerySpan.Stop.self),
    .distribution(QuerySpan.Stop.self, \.duration, unit: .milliseconds, tags: \.table),
    .sum(Query.self, \.rows, tags: \.table),
    .lastValue(PoolStats.self, \.idle),
    .counter(QuerySpan.Exception.self, tags: \.errorType, keep: { $0.table != "audit" }),
]
```

- **Type-checked.** The measured field is a `TelemetryMeasurement` of
  *this* event's `Measurements`, and every tag is a `TagValue` of *its*
  `Metadata`. Tags are a parameter pack, so any number of them work.
- **Named** after the event, plus the field for a measured metric:
  `hangar.query.stop.duration`. `name:` overrides it. swift-metrics sees
  underscores: `hangar_query_stop_duration`.
- **`keep:`** filters on the metadata before anything is recorded.
- **`TelemetryMetric.all { … }`** builds the list with `if` and `for`
  where an array literal won't do.

These are static members rather than `Counter(…)` types because
swift-metrics already has a `Counter`, and an application imports both.

### Contributing metrics

A module contributes metrics by holding them. `FlightTelemetryModule`
collects every included module's `[TelemetryMetric]`, the same way
composition collects routes and channels (D15). That's how Flight's own
modules declare theirs, and how yours, or a package Flight has never heard
of, declares its own:

```swift
struct AppModule: FlightModule {
    let telemetryMetrics: [TelemetryMetric] = [
        .distribution(Checkout.Stop.self, \.duration, unit: .milliseconds, tags: \.method)
    ]
}
```

Two definitions with one name fail composition, naming both events.

### Reporting

`SwiftMetricsReporter` maps definitions onto swift-metrics:

| Definition | swift-metrics |
|---|---|
| counter | `Counter.increment()` |
| sum | `Counter.increment(by:)`, or `FloatingPointCounter` for fractional values |
| lastValue | `Gauge.record` |
| distribution of a `Duration` | `Timer.recordNanoseconds`, displayed in `unit` |
| distribution of a number | `Recorder(aggregate: true).record` |

It translates and never aggregates; the backend does that. **Cardinality is
capped**: each metric keeps at most 1,000 tag combinations
(`telemetry.metrics.cardinality-limit`). Past that, values are recorded
with every tag set to `_overflow`, and
`TelemetryCardinalityExceeded` is emitted once for the metric. Totals stay
right, and an unbounded label nobody meant cannot take the backend down.

## Handlers

```swift
let token = try Telemetry.attach(QuerySpan.Stop.self, id: "slow-queries") { measurements, metadata, _ in
    if measurements.duration > .seconds(1) { slowQueries.record(metadata.table) }
}

let all = try Telemetry.attach(prefix: "hangar", id: "debug") { event in
    print(event.name)   // everything under hangar.*, whatever its type
}
```

A **typed** handler gets the payload by type, with no boxing and no
dictionary. An **erased** handler gets every event under a prefix through
`AnyEvent`, and reads fields with `forEachMeasurement` and
`forEachMetadata`. That's for logging and debugging: it pays for
existentials when it reads, which a typed handler doesn't. `EventName.all`
is the prefix of everything.

Attaching returns a noncopyable **`HandlerToken`**, and the handler stays
attached for as long as the token lives. When it's dropped, or `detach()`
is called, the handler is detached, so a test or a short-lived service
can't leak one. `persist()` keeps it for the life of the process;
`HandlerTokens` holds several. A second handler with the same `id` on the
same event is refused (`AttachError.duplicateID`).

### The rules

- **Handlers are synchronous.** They run on the emitting thread, in attach
  order, typed before erased, and may run concurrently on different
  threads. Emitting is legal anywhere, even inside a lock, as long as the
  handler doesn't take that lock itself.
- **Handlers are quick and don't block.** Nothing times them out; a slow
  handler slows the emitter. Move heavy work to an `AsyncStream` consumer.
- **A handler that throws is detached**, and `TelemetryHandlerFailed` is
  emitted naming the event, the handler and the error type. Other handlers
  still run. A handler that *traps* crashes the process, since Swift can't
  catch a trap. This is the one real difference from the BEAM.
- **Re-entry is capped at 8.** A handler that emits, whose handler emits,
  and so on, has its nested emits dropped past that depth, with a warning
  once per event type.

### The detach guarantee

When `detach()` returns, the handler is never called again, not even by an
emit already under way on another thread. `detach` waits for such emits to
finish, which is why handlers mustn't block.

There's one exception. Detaching from *inside* a handler doesn't wait:
that thread is itself mid-emit, and two threads each detaching the other's
handler would wait on each other forever. It takes effect for every emit
that starts afterwards.

### The context

The third argument is an `EventContext`: the `timestamp`, the
`serviceContext`, and the `spanID` of the span the event was emitted
inside. It's a view, like `AnyEvent`: noncopyable and borrowed. Each value
is read the first time a handler asks, and shared with every handler after
that. An emit whose handlers never ask (a metrics reporter never does)
pays for neither the clock nor the task-local read. `snapshot()` keeps a
copy.

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
    .log(prefix: "flight.sessions", level: .debug)
    .attach()
```

`Logger.MetadataProvider.telemetry` puts `telemetry.span_id` on every log
line written inside a span, including plain `logger.info` calls:

```swift
LoggingSystem.bootstrap(StreamLogHandler.standardOutput, metadataProvider: .telemetry)
```

A `SpanObserver` is the general form of the tracing bridge, for anything
that must carry state from a span's start to its end, or change the
context its body runs in.

## Testing

```swift
@Test func signInCountsFailures() async throws {
    let attempts = await TelemetryTest.capture(SignInEvents.Attempt.self) {
        _ = try? await authenticator.authenticate(identifier: "ada", password: "wrong", clientAddress: nil)
    }
    #expect(attempts.map(\.metadata.outcome) == ["invalid_credentials"])
}
```

A capture sees only its own body's emits, including those from child tasks
and from requests through `TestClient`, even with every other test in the
process emitting the same events at the same time. It binds a scope in a
task-local, and one shared handler per event type records an emit only for
the scopes current where it happens. Production pays nothing for this:
only handlers that exist during a capture read the task-local.

- `capture(E.self)` returns `[CapturedEvent<E>]`, typed.
- `capture(prefix:)` returns `[CapturedAnyEvent]`, with fields by name
  (`event[metadata: "outcome"]`).
- `captureSpans(S.self)` returns every phase.
- `expectNoEmission(prefix:)` throws, listing what was emitted, which fails
  the test under any framework.

Not captured: work that leaves structured concurrency, such as
`Task.detached` or a NIO event loop that doesn't carry task-locals across.

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

## Performance

These are the spec's targets, measured by `Benchmarks/` in a release build
on x86_64 Linux:

| | Target | Measured | Allocations |
|---|---|---|---|
| emit, nothing attached | ≤ 2 ns | ~1.7 ns | 0 |
| span, nothing attached (overhead) | ≤ 5 ns | ~1.8 ns | 0 |
| emit, one typed no-op handler | ≤ 40 ns | ~23 ns | 0 |
| emit, one erased no-op handler | ≤ 80 ns | ~53 ns | 0 |

```sh
cd Benchmarks && swift run -c release TelemetryBenchmarks
```

It exits non-zero on a miss. CI enforces the allocation counts on every
push. A 2 ns line can't be held on a shared runner, so latency is enforced
before a release, on a quiet machine.

How it gets there:

- **One word on the fast path.** Each event type has a slot, and its
  flags word says whether typed handlers exist, and whether any erased
  handler or span observer exists anywhere. The registry keeps those last
  two bits current on every slot.
- **No lock to read.** An emit reads the published handler list after one
  atomic increment and leaves with one decrement, however many handlers
  there are. Attaching and detaching swap the list and wait out a grace
  period before freeing the old one; that wait is also the detach
  guarantee.
- **A lazy context.** The clock and the task-local are read only if a
  handler asks.
- **Specialized.** The dispatch loop is inlined at the emit, so handlers
  get the payload's concrete types with no generic copies.

## For library authors

- Depend on `FlightTelemetry` alone. Never bootstrap a backend, and never
  attach a handler in library code. Those are the application's to decide.
- Put events in a public namespace, document them, and treat them as API.
- Use spans for operations with a duration, and events for things that
  happen at a point in time.
- Keep metadata low-cardinality. Put anything unbounded (SQL, ids, user
  input) in an optional field, filled only when a setting asks for it.
- Contribute metric definitions from your module if you have a
  `FlightModule`. They're reported wherever the application reports
  metrics, under the names you give them.

## Not here

- **A poller.** A `@Scheduled` job that emits is one. `FlightScheduler`
  already runs work on an interval.
- **`@Instrumented`**, the body macro that would wrap a function in a span.
  It's deferred, and `Telemetry.span` is the supported path.
- **Summaries** (client-side quantiles). Backends compute quantiles from
  histograms better than a client can.
