// expect: Request.Measurements
// A distribution measures a measurement, not a metadata field.
import FlightTelemetry

@TelemetryEvent("probe.request")
enum Request {
    struct Measurements { var bytes: Int }
    struct Metadata { var status: Int }
}

let metric = TelemetryMetric.distribution(Request.self, \Request.Metadata.status)
