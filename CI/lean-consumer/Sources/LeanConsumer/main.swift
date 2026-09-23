import FlightCore
import FlightTelemetry

// Existing is the whole test: what matters is what Package.resolved holds.
// The event is here so the telemetry core — and its macro — are built, not
// merely resolved.
@TelemetryEvent("lean.started")
enum Started {}

@main
struct LeanConsumer {
    static func main() {
        Telemetry.emit(Started.self)
        print("ok")
    }
}
