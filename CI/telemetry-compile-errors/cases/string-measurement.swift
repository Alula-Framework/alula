// expect: conform to 'TelemetryMeasurement'
// A measurement is a number: a string one is refused where it is declared.
import FlightTelemetry

@TelemetryEvent("probe.request")
enum Request {
    struct Measurements { var route: String }
}
