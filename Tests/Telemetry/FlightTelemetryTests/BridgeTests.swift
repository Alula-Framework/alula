#if Telemetry
    import FlightCore
    import FlightTelemetry
    import FlightTelemetryBridges
    import InMemoryTracing
    import Logging
    import CoreMetrics
    import MetricsTestKit
    import ServiceContextModule
    import Synchronization
    import Testing
    import Tracing

    @TelemetryEvent("bridgetest.request")
    enum BridgeRequest {
        struct Measurements {
            var duration: Duration
            var bytes: Int
            var ratio: Double
        }
        struct Metadata {
            var route: String
            var ok: Bool
        }
    }

    @TelemetrySpan("bridgetest.fetch", kind: .client)
    enum BridgeFetch {
        struct Metadata { var key: String }
        struct StopMetadata { var rows: Int = 0 }
    }

    private func emitRequest(_ route: String, bytes: Int = 10, ok: Bool = true) {
        Telemetry.emit(BridgeRequest.self) {
            (
                .init(duration: .milliseconds(20), bytes: bytes, ratio: 0.25),
                .init(route: route, ok: ok)
            )
        }
    }

    extension CoreTests {
        @Suite("swift-metrics reporter")
        struct SwiftMetricsReporterTests {
            @Test("each kind maps to its instrument, named with underscores, tagged by dimensions")
            func mapping() throws {
                let metrics = TestMetrics()
                let tokens = try SwiftMetricsReporter(factory: metrics).attach([
                    .counter(BridgeRequest.self, tags: \.route),
                    .sum(BridgeRequest.self, \.bytes),
                    .sum(BridgeRequest.self, \.ratio),
                    .lastValue(BridgeRequest.self, \.bytes, name: "bridgetest.request.last_bytes"),
                    .distribution(BridgeRequest.self, \.duration, unit: .milliseconds, tags: \.ok),
                ])
                emitRequest("/a", bytes: 10)
                emitRequest("/a", bytes: 5)
                emitRequest("/b", bytes: 1, ok: false)
                emitRequest("/c", bytes: 0)

                #expect(
                    try metrics.expectCounter("bridgetest_request", [("route", "/a")]).totalValue
                        == 2)
                #expect(
                    try metrics.expectCounter("bridgetest_request", [("route", "/b")]).totalValue
                        == 1)
                #expect(
                    try metrics.expectCounter("bridgetest_request", [("route", "/c")]).totalValue
                        == 1)
                #expect(try metrics.expectCounter("bridgetest_request_bytes").totalValue == 16)
                // A fractional sum goes to a FloatingPointCounter, which the
                // default factory accumulates into an integer counter: four
                // quarters make one.
                #expect(try metrics.expectCounter("bridgetest_request_ratio").totalValue == 1)
                #expect(try metrics.expectGauge("bridgetest_request_last_bytes").lastValue == 0)
                let timer = try metrics.expectTimer("bridgetest_request_duration", [("ok", "true")])
                #expect(timer.values == [20_000_000, 20_000_000, 20_000_000])
                _ = consume tokens
            }

            @Test(
                "past the cardinality limit, values land under _overflow and the event fires once")
            func cardinality() throws {
                let metrics = TestMetrics()
                let tokens = try SwiftMetricsReporter(factory: metrics, cardinalityLimit: 2).attach(
                    [
                        .counter(BridgeRequest.self, name: "bridgetest.capped", tags: \.route)
                    ])
                let exceeded = Recorder<String>()
                let watch = try Telemetry.attach(TelemetryCardinalityExceeded.self, id: "watch") {
                    _, metadata, _ in
                    if metadata.metric == "bridgetest.capped" { exceeded.append(metadata.metric) }
                }
                for route in ["/1", "/2", "/3", "/4", "/3"] { emitRequest(route) }

                #expect(
                    try metrics.expectCounter("bridgetest_capped", [("route", "/1")]).totalValue
                        == 1)
                #expect(
                    try metrics.expectCounter("bridgetest_capped", [("route", "/2")]).totalValue
                        == 1)
                #expect(
                    try metrics.expectCounter("bridgetest_capped", [("route", "_overflow")])
                        .totalValue == 3)
                #expect(exceeded.count == 1)
                _ = consume tokens
                _ = consume watch
            }
        }

        @Suite("Tracing observer")
        struct TracingObserverTests {
            @Test("spans become tracing spans: kind, attributes, parents, errors")
            func tracing() throws {
                struct Boom: Error {}
                let tracer = InMemoryTracer()
                let token = try Telemetry.observeSpans(
                    prefix: "bridgetest", id: "tracing", TracingObserver(tracer: tracer))

                Telemetry.span(BridgeFetch.self, metadata: .init(key: "outer")) { span in
                    span.stopMetadata.rows = 3
                    Telemetry.span(BridgeFetch.self, metadata: .init(key: "inner")) { _ in }
                }
                _ = try? Telemetry.span(BridgeFetch.self, metadata: .init(key: "bad")) {
                    (_: inout SpanHandle<BridgeFetch>) throws(Boom) in throw Boom()
                }

                let spans = tracer.finishedSpans
                #expect(spans.count == 3)
                let inner = try #require(
                    spans.first { $0.attributes["key"]?.toSpanAttribute() == .string("inner") })
                let outer = try #require(
                    spans.first { $0.attributes["key"]?.toSpanAttribute() == .string("outer") })
                let bad = try #require(
                    spans.first { $0.attributes["key"]?.toSpanAttribute() == .string("bad") })
                #expect(outer.operationName == "bridgetest.fetch")
                #expect(outer.kind == .client)
                #expect(outer.attributes["rows"]?.toSpanAttribute() == .int64(3))
                #expect(
                    inner.spanContext.parentSpanID == outer.spanContext.spanID,
                    "a telemetry span inside another is its child")
                #expect(inner.spanContext.traceID == outer.spanContext.traceID)
                #expect(bad.status?.code == .error)
                #expect(bad.errors.count == 1)
                _ = consume token
            }
        }

        @Suite("Log bridge")
        struct LogBridgeTests {
            @Test(
                "typed and prefix rules log the event name with its fields; the level gates first")
            func logging() throws {
                let lines = Recorder<String>()
                var logger = Logger(label: "bridge") { _ in CapturingLogHandler(lines: lines) }
                logger.logLevel = .info
                let tokens = try LogBridge(logger: logger)
                    .log(BridgeRequest.self, level: .info)
                    .log(prefix: "bridgetest", level: .debug)  // below the logger's level: silent
                    .attach()
                emitRequest("/x")
                #expect(
                    lines.all == [
                        "info bridgetest.request bytes=10 duration=0.02 seconds ok=true ratio=0.25 route=/x"
                    ])
                _ = consume tokens
            }

            @Test("the metadata provider stamps the telemetry span on any log line inside one")
            func metadataProvider() throws {
                let observed = try Telemetry.observeSpans(
                    prefix: "bridgetest", id: "provider", NoopObserver())
                let inside = Telemetry.span(BridgeFetch.self, metadata: .init(key: "k")) { _ in
                    Logger.MetadataProvider.telemetry.get()
                }
                #expect(inside["telemetry.span_id"] != nil)
                #expect(Logger.MetadataProvider.telemetry.get().isEmpty, "nothing outside a span")
                _ = consume observed
            }
        }

        @Suite("Telemetry module")
        struct TelemetryModuleTests {
            @Test("reports contributed metrics and its own; refuses two metrics with one name")
            func module() throws {
                let metrics = TestMetrics()
                let module = try FlightTelemetryModule(
                    configuration: Configuration(),
                    metrics: [.counter(BridgeRequest.self, name: "bridgetest.module")],
                    metricsFactory: metrics)
                #expect(
                    module.reportedMetrics.map(\.descriptor.name) == [
                        "bridgetest.module", "flight.telemetry.handler_failed",
                        "flight.telemetry.cardinality_exceeded",
                    ])
                emitRequest("/m")
                #expect(try metrics.expectCounter("bridgetest_module").totalValue == 1)

                #expect(
                    throws: TelemetryConfigurationError.duplicateMetric(
                        name: "bridgetest_dup",
                        events: ["bridgetest.request", "bridgetest.fetch.stop"])
                ) {
                    _ = try FlightTelemetryModule(
                        configuration: Configuration(),
                        metrics: [
                            .counter(BridgeRequest.self, name: "bridgetest.dup"),
                            .counter(BridgeFetch.Stop.self, name: "bridgetest.dup"),
                        ],
                        metricsFactory: TestMetrics())
                }
            }

            @Test(
                "with no metrics backend and no tracer bootstrapped, nothing is attached — and nothing is paid"
            )
            func autoOff() throws {
                let module = try FlightTelemetryModule(
                    configuration: Configuration(),
                    metrics: [.counter(BridgeRequest.self, name: "bridgetest.auto")],
                    metricsFactory: NOOPMetricsHandler.instance)
                #expect(!module.metricsEnabled)
                #expect(!module.tracingEnabled, "no tracer is bootstrapped in this process")
                #expect(!Telemetry.isEnabled(BridgeRequest.self))

                let forced = try FlightTelemetryModule(
                    configuration: Configuration(values: ["telemetry.metrics.enabled": "true"]),
                    metrics: [.counter(BridgeRequest.self, name: "bridgetest.auto")],
                    metricsFactory: NOOPMetricsHandler.instance)
                #expect(forced.metricsEnabled)
                #expect(Telemetry.isEnabled(BridgeRequest.self))
            }

            @Test("settings: defaults, and bad values fail composition naming the key")
            func settings() throws {
                let defaults = try TelemetrySettings(configuration: Configuration())
                #expect(
                    defaults.metricsEnabled == nil && defaults.tracingEnabled == nil,
                    "decided by what is bootstrapped")
                #expect(defaults.logPrefix == nil)
                #expect(defaults.tracingPrefix == .all && defaults.cardinalityLimit == 1000)

                let custom = try TelemetrySettings(
                    configuration: Configuration(values: [
                        "telemetry.tracing.enabled": "true", "telemetry.tracing.prefix": "hangar",
                        "telemetry.log.prefix": "flight.sessions", "telemetry.log.level": "INFO",
                    ]))
                #expect(custom.tracingEnabled == true && custom.tracingPrefix == "hangar")
                #expect(custom.logPrefix == "flight.sessions" && custom.logLevel == .info)

                #expect(
                    throws: TelemetryConfigurationError.invalidPrefix(
                        key: "telemetry.log.prefix", value: "Flight")
                ) {
                    _ = try TelemetrySettings(
                        configuration: Configuration(values: ["telemetry.log.prefix": "Flight"]))
                }
                #expect(throws: TelemetryConfigurationError.invalidLogLevel("loud")) {
                    _ = try TelemetrySettings(
                        configuration: Configuration(values: ["telemetry.log.level": "loud"]))
                }
                #expect(throws: TelemetryConfigurationError.invalidCardinalityLimit(0)) {
                    _ = try TelemetrySettings(
                        configuration: Configuration(values: [
                            "telemetry.metrics.cardinality-limit": "0"
                        ]))
                }
            }
        }
    }

    private struct NoopObserver: SpanObserver {
        func start(_ span: borrowing SpanStart, context: inout ServiceContext) {}
        func stop(_ span: borrowing SpanStop, state: consuming ()) {}
        func exception(_ span: borrowing SpanFailure, state: consuming ()) {}
    }

    private struct CapturingLogHandler: LogHandler {
        let lines: Recorder<String>
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            let fields = (event.metadata ?? [:]).sorted { $0.key < $1.key }.map {
                "\($0.key)=\($0.value)"
            }
            lines.append(
                ([event.level.rawValue, "\(event.message)"] + fields).joined(separator: " "))
        }
    }
#endif
