// Every shape Docs/telemetry.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import FlightCore
import FlightSecurityCore
import FlightTelemetry
import FlightTelemetryBridges
import FlightTelemetryTesting
import FlightWeb
import Logging

// snippet.hide
func run(_ sql: String) async throws -> [Int] { [] }
let sql = "select 1"
let elapsed = Duration.milliseconds(3)
let rows = [1, 2, 3]
let ended = 2
enum Checkout {
    @TelemetrySpan("shop.checkout")
    enum Span {
        struct Metadata { var method: String }
    }
    typealias Stop = Span.Stop
}
@TelemetryEvent("pool.stats")
enum PoolStats {
    struct Measurements { var idle: Int }
}
struct SlowQueries: Sendable { func record(_ table: String) {} }
let slowQueries = SlowQueries()
// snippet.show

// MARK: Declaring an event

@TelemetryEvent("hangar.query")
public enum Query {
    public struct Measurements {
        public var duration: Duration
        public var rows: Int
    }
    public struct Metadata {
        public var table: String
        public var statement: String? = nil  // opt-in, high-cardinality
    }
}

// MARK: Emitting

func emitting() async throws {
    Telemetry.emit(Query.self) {
        (.init(duration: elapsed, rows: rows.count), .init(table: "users"))
    }
    Telemetry.emit(SessionEvents.Created.self)
    Telemetry.emit(SessionEvents.StoreFailed.self) { .init(operation: "save") }
    Telemetry.emit(SessionEvents.Revoked.self) { .init(sessions: ended) }
}

func emittingWithAClock() async throws {
    let start = Telemetry.isEnabled(Query.self) ? ContinuousClock.now : nil
    let rows = try await run(sql)
    Telemetry.emit(Query.self) {
        (.init(duration: start.map { .now - $0 } ?? .zero, rows: rows.count), .init(table: "users"))
    }
}

// MARK: Spans

@TelemetrySpan("hangar.query", kind: .client)
public enum QuerySpan {
    public struct Metadata { public var table: String }
    public struct StopMetadata { public var rows: Int = 0 }
}

func spans() async throws -> [Int] {
    let rows = try await Telemetry.span(QuerySpan.self, metadata: .init(table: "users")) { span in
        let rows = try await run(sql)
        span.stopMetadata.rows = rows.count
        return rows
    }
    return rows
}

// MARK: Metrics

let metrics: [TelemetryMetric] = [
    .counter(QuerySpan.Stop.self),
    .distribution(QuerySpan.Stop.self, \.duration, unit: .milliseconds, tags: \.table),
    .sum(Query.self, \.rows, tags: \.table),
    .lastValue(PoolStats.self, \.idle),
    .counter(QuerySpan.Exception.self, tags: \.errorType, keep: { $0.table != "audit" }),
]

func conditional(detailed: Bool) -> [TelemetryMetric] {
    TelemetryMetric.all {
        TelemetryMetric.counter(QuerySpan.Stop.self)
        if detailed {
            TelemetryMetric.distribution(QuerySpan.Stop.self, \.duration, tags: \.table)
        }
    }
}

struct AppModule: FlightModule {
    let telemetryMetrics: [TelemetryMetric] = [
        .distribution(Checkout.Stop.self, \.duration, unit: .milliseconds, tags: \.method)
    ]
}

// MARK: Handlers

func handlers() throws {
    let token = try Telemetry.attach(QuerySpan.Stop.self, id: "slow-queries") {
        measurements, metadata, _ in
        if measurements.duration > .seconds(1) { slowQueries.record(metadata.table) }
    }

    let all = try Telemetry.attach(prefix: "hangar", id: "debug") { event in
        print(event.name)  // everything under hangar.*, whatever its type
    }
    _ = consume token
    _ = consume all
}

// MARK: Tracing and logs

func tracingAndLogs() throws {
    let token = try Telemetry.observeSpans(prefix: "hangar", id: "tracing", TracingObserver())

    let tokens = try LogBridge(logger: Logger(label: "telemetry"))
        .log(QuerySpan.Exception.self, level: .error)
        .log(prefix: "flight.sessions", level: .debug)
        .attach()
    _ = consume token
    _ = consume tokens
}

func bootstrapLogging() {
    LoggingSystem.bootstrap(StreamLogHandler.standardOutput, metadataProvider: .telemetry)
}

// MARK: Testing

func testing(authenticator: PasswordAuthenticator) async throws {
    let attempts = await TelemetryTest.capture(SignInEvents.Attempt.self) {
        _ = try? await authenticator.authenticate(
            identifier: "ada", password: "wrong", clientAddress: nil)
    }
    precondition(attempts.map(\.metadata.outcome) == ["invalid_credentials"])
}
