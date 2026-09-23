import FlightTelemetry
import FlightTelemetryTesting
import Synchronization
import Testing

@TelemetryEvent("metrictest.request")
enum MetricRequest {
    struct Measurements {
        var duration: Duration
        var bytes: Int
        var load: Double
    }
    struct Metadata {
        var route: String
        var status: Int
        var cached: Bool
        var note: String? = nil
    }
}

/// Records what a reporter would be handed.
final class RecordingRecorder: MetricRecorder {
    let records = Recorder<(MeasurementValue, [String])>()
    func record(_ value: MeasurementValue, tags: [String]) { records.append((value, tags)) }
}

extension CoreTests {
    @Suite("Metric definitions")
    struct MetricDefinitionTests {
        @Test(
            "names, kinds, fields, and tag keys come from the event and its generated field names")
        func descriptors() {
            let metrics: [TelemetryMetric] = [
                .counter(MetricRequest.self),
                .counter(MetricRequest.self, name: "requests.total", tags: \.route, \.status),
                .sum(MetricRequest.self, \.bytes, tags: \.route),
                .lastValue(MetricRequest.self, \.load),
                .distribution(
                    MetricRequest.self, \.duration, unit: .milliseconds,
                    buckets: .exponential(start: 1, factor: 2, count: 4), tags: \.route, \.cached),
            ]
            let descriptors = metrics.map(\.descriptor)
            #expect(
                descriptors.map(\.name) == [
                    "metrictest.request", "requests.total", "metrictest.request.bytes",
                    "metrictest.request.load", "metrictest.request.duration",
                ])
            #expect(
                descriptors.map(\.kind) == [.counter, .counter, .sum, .lastValue, .distribution])
            #expect(descriptors.map(\.field) == [nil, nil, "bytes", "load", "duration"])
            #expect(
                descriptors.map(\.tags) == [
                    [], ["route", "status"], ["route"], [], ["route", "cached"],
                ])
            #expect(descriptors[4].buckets?.boundaries == [1, 2, 4, 8])
            #expect(descriptors[4].number(.duration(.milliseconds(250))) == 250)
            #expect(
                descriptors[3].number(.duration(.milliseconds(250))) == 0.25,
                "seconds without a unit")
        }

        @Test("attached, a definition feeds values and tag values; keep filters")
        func recording() throws {
            let count = RecordingRecorder()
            let bytes = RecordingRecorder()
            let a = try TelemetryMetric.counter(
                MetricRequest.self, tags: \.route, \.status, \.cached,
                keep: { $0.route != "/health" }
            ).attach(recording: count, id: "count")
            let b = try TelemetryMetric.sum(MetricRequest.self, \.bytes).attach(
                recording: bytes, id: "bytes")

            for (route, size) in [("/users", 10), ("/health", 1), ("/users", 30)] {
                Telemetry.emit(MetricRequest.self) {
                    (
                        .init(duration: .milliseconds(5), bytes: size, load: 0.5),
                        .init(route: route, status: 200, cached: false)
                    )
                }
            }
            #expect(
                count.records.all.map(\.1) == [
                    ["/users", "200", "false"], ["/users", "200", "false"],
                ])
            #expect(bytes.records.all.map { $0.0 } == [.integer(10), .integer(1), .integer(30)])
            #expect(bytes.records.all.allSatisfy { $0.1.isEmpty })
            _ = consume a
            _ = consume b
        }

        @Test("the builder takes conditions and loops")
        func builder() {
            let detailed = true
            let metrics = TelemetryMetric.all {
                TelemetryMetric.counter(MetricRequest.self)
                if detailed {
                    TelemetryMetric.distribution(MetricRequest.self, \.duration, tags: \.route)
                }
                for route in ["a", "b"] {
                    TelemetryMetric.counter(
                        MetricRequest.self, name: "route.\(route)", keep: { $0.route == route })
                }
            }
            #expect(
                metrics.map(\.descriptor.name) == [
                    "metrictest.request", "metrictest.request.duration", "route.a", "route.b",
                ])
        }
    }

    @Suite("Capturing in tests")
    struct CaptureTests {
        @Test(
            "a capture sees its own body's emits — including child tasks — and not a concurrent capture's"
        )
        func isolation() async throws {
            func emit(_ route: String) {
                Telemetry.emit(MetricRequest.self) {
                    (
                        .init(duration: .zero, bytes: 0, load: 0),
                        .init(route: route, status: 200, cached: true)
                    )
                }
            }
            let results = await withTaskGroup(of: [String].self) { group in
                for name in ["left", "right"] {
                    group.addTask {
                        let captured = await TelemetryTest.capture(MetricRequest.self) {
                            for _ in 0..<50 {
                                emit(name)
                                await Task.yield()
                            }
                            await withTaskGroup(of: Void.self) { children in
                                children.addTask { emit(name + "-child") }
                            }
                        }
                        return captured.map(\.metadata.route)
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            for routes in results {
                let own = routes.first!
                #expect(routes.count == 51)
                #expect(Set(routes) == [own, own + "-child"], "never the other capture's events")
            }
            emit("outside")  // after both captures: no handler, nothing recorded, nothing crashes
            #expect(
                !Telemetry.isEnabled(MetricRequest.self),
                "the shared handler detached with the last capture")
        }

        @Test(
            "prefix captures see every type, fields by name; expectNoEmission throws with what was emitted"
        )
        func erased() throws {
            let events = TelemetryTest.capture(prefix: "metrictest") {
                Telemetry.emit(MetricRequest.self) {
                    (
                        .init(duration: .zero, bytes: 7, load: 0),
                        .init(route: "/x", status: 404, cached: false)
                    )
                }
            }
            #expect(events.count == 1)
            #expect(events[0][metadata: "status"] == "404")
            #expect(events[0][metadata: "note"] == nil, "nil optionals are absent")
            #expect(
                events[0].description
                    == "metrictest.request duration=0.0 seconds bytes=7 load=0.0 route=/x status=404 cached=false"
            )

            try TelemetryTest.expectNoEmission(prefix: "metrictest") {}
            let error = #expect(throws: UnexpectedEmission.self) {
                try TelemetryTest.expectNoEmission(prefix: "metrictest.request") {
                    Telemetry.emit(MetricRequest.self) {
                        (
                            .init(duration: .zero, bytes: 0, load: 0),
                            .init(route: "/y", status: 200, cached: true)
                        )
                    }
                }
            }
            #expect(error?.description.contains("route=/y") == true)
        }

        @Test("overlapping prefix captures, live at once, each see an event exactly once")
        func overlappingPrefixes() async {
            // Both handlers see every metrictest.request emit; each capture
            // must take it only from its own. This counted everything twice
            // when a broader capture elsewhere in the process was live.
            let broad = TelemetryTest.capture(prefix: "metrictest") {
                let narrow = TelemetryTest.capture(prefix: "metrictest.request") {
                    Telemetry.emit(MetricRequest.self) {
                        (
                            .init(duration: .zero, bytes: 1, load: 0),
                            .init(route: "/o", status: 200, cached: true)
                        )
                    }
                }
                #expect(narrow.count == 1)
            }
            #expect(broad.count == 1)
        }

        @Test("span captures collect every phase")
        func spans() async throws {
            struct Failure: Error {}
            let spans = await TelemetryTest.captureSpans(Fetch.self) {
                Telemetry.span(Fetch.self, metadata: .init(key: "a")) { span in
                    span.stopMetadata.bytes = 1
                }
                _ = try? Telemetry.span(Fetch.self, metadata: .init(key: "b")) {
                    (_: inout SpanHandle<Fetch>) throws(Failure) in throw Failure()
                }
            }
            #expect(spans.starts.map(\.metadata.key) == ["a", "b"])
            #expect(spans.stops.map(\.metadata.bytes) == [1])
            #expect(spans.exceptions.map(\.metadata.key) == ["b"])
        }
    }
}
