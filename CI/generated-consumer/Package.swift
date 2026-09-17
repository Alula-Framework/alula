// swift-tools-version: 6.2
import PackageDescription

// A CI fixture, not a shipped product. It pins the one property the generator
// test suite structurally cannot: that the Swift file the plugin emits
// actually compiles.
//
// Those tests drive the real executable and assert on its text and exit code,
// which is the right contract for diagnostics — but it means a generated file
// can be syntactically fine, contain every expected substring, and still not
// build. That is not hypothetical: the graph initializer emitted
// `x ?? (try C())` for any component with a @ConfigValue, which Swift rejects
// because `??` takes its right side as an autoclosure. A test asserted that
// exact spelling and passed, while every real application with a
// configuration-reading component failed to build.
//
// Compiling one representative output is the cheap half of closing that gap.
let package = Package(
    name: "generated-consumer",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..", traits: [])],
    targets: [
        .executableTarget(
            name: "GeneratedConsumer",
            dependencies: [.product(name: "FlightCore", package: "flight")],
            plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight")]
        )
    ]
)
