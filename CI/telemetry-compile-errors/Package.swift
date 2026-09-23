// swift-tools-version: 6.3
import PackageDescription

// A CI fixture, not a shipped product. It pins what the telemetry API
// promises the compiler refuses: a measurement that is not a number, a tag
// that is not a tag, a tag from another event. Those promises are the point
// of typed events, and a promise nothing checks is one a refactor quietly
// breaks. `check-telemetry-compile-errors.sh` builds each file in `cases/`
// as this target's only source and requires the build to fail, saying why.
let package = Package(
    name: "telemetry-compile-errors",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..", traits: [])],
    targets: [
        .target(
            name: "Probe",
            dependencies: [.product(name: "FlightTelemetry", package: "flight")]
        )
    ]
)
