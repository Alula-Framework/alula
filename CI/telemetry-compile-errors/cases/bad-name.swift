// expect: is not a valid event name
// Names are checked at build time, by the macro.
import FlightTelemetry

@TelemetryEvent("Probe.Request")
enum Request {}
