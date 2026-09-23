// expect: conform to 'TagValue'
// A tag is a closed, low-cardinality value; a Double is not one.
import FlightTelemetry

@TelemetryEvent("probe.request")
enum Request {
    struct Measurements { var bytes: Int }
    struct Metadata { var ratio: Double }
}

let metric = TelemetryMetric.counter(Request.self, tags: \.ratio)
