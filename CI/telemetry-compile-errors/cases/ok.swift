// expect: compiles
// The positive control: the same shapes, used correctly. If this fails,
// every refusal below proves nothing.
import FlightTelemetry

@TelemetryEvent("probe.request")
enum Request {
    struct Measurements { var duration: Duration; var bytes: Int }
    struct Metadata { var route: String; var cached: Bool }
}

let metrics: [TelemetryMetric] = [
    .counter(Request.self, tags: \.route, \.cached),
    .distribution(Request.self, \.duration, unit: .milliseconds, tags: \.route),
    .sum(Request.self, \.bytes),
]
