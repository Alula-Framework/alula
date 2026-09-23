// swift-tools-version: 6.3
import PackageDescription

// Not part of the flight package: benchmarks build in release, depend on the
// package by path, and would otherwise put an executable and a malloc
// interposer into every consumer's graph.
//
//     swift run -c release TelemetryBenchmarks
//
// Exits non-zero when a target in the telemetry spec is missed — an
// allocation always, a latency unless `--no-latency` (for a noisy runner).
let package = Package(
    name: "flight-benchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "..")],
    targets: [
        // Counts allocations on the calling thread. glibc only: it wraps
        // malloc and friends around __libc_malloc. Elsewhere it reports
        // itself unsupported and the allocation checks are skipped, loudly.
        .target(name: "CAllocationCounter", path: "Sources/CAllocationCounter"),
        .executableTarget(
            name: "TelemetryBenchmarks",
            dependencies: [
                .product(name: "FlightTelemetry", package: "flight"),
                "CAllocationCounter",
            ],
            path: "Sources/TelemetryBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
