// expect: Other.Metadata
// A tag names a field of *this* event's metadata, not another's.
import FlightTelemetry

@TelemetryEvent("probe.request")
enum Request {
    struct Metadata { var route: String }
}

@TelemetryEvent("probe.other")
enum Other {
    struct Metadata { var queue: String }
}

let metric = TelemetryMetric.counter(Request.self, tags: \Other.Metadata.queue)
