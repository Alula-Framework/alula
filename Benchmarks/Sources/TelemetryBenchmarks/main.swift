import CAllocationCounter
import FlightTelemetry
import Foundation
import ServiceContextModule

// The performance targets from the telemetry spec, measured and enforced:
//
//     emit, nothing attached           ≤ 2 ns    0 allocations
//     emit, one typed no-op handler    ≤ 40 ns   0 allocations
//     emit, one erased no-op handler   ≤ 80 ns   0 allocations
//     span, nothing attached           ≤ 5 ns    0 allocations (overhead)
//
// Each latency is the median of 15 batches of a million operations; each
// allocation count is over 100,000 operations on this thread. Order matters:
// an erased handler anywhere puts every event on the slow path, so the
// nothing-attached scenarios run first.

@TelemetryEvent("bench.nothing")
enum Nothing {
    struct Measurements { var value: Int }
    struct Metadata { var route: String }
}

@TelemetryEvent("bench.typed")
enum Typed {
    struct Measurements { var value: Int }
    struct Metadata { var route: String }
}

@TelemetryEvent("bench.erased")
enum Erased {
    struct Measurements { var value: Int }
    struct Metadata { var route: String }
}

@TelemetrySpan("bench.span")
enum Load {
    struct Metadata { var key: String }
}

struct NoObserver: SpanObserver {
    func start(_ span: borrowing SpanStart, context: inout ServiceContext) {}
    func stop(_ span: borrowing SpanStop, state: consuming ()) {}
    func exception(_ span: borrowing SpanFailure, state: consuming ()) {}
}

@inline(never)
func blackHole<T>(_ value: T) { withExtendedLifetime(value) {} }

struct Scenario {
    let name: String
    let latencyTarget: Double
    /// Subtracted from the measured time: the same closure without the
    /// telemetry call — the harness's own indirect call and counter, and for
    /// a span, calling the body directly — so the figure is telemetry's cost
    /// alone, which is what the targets are.
    let baseline: () -> Void
    let operation: () -> Void
}

let arguments = CommandLine.arguments.dropFirst()
let enforceLatency = !arguments.contains("--no-latency")
let batches = 15
let batchSize = 1_000_000

@MainActor
func nanosecondsPerOperation(_ operation: () -> Void) -> Double {
    var samples: [Double] = []
    for _ in 0..<batches {
        let start = ContinuousClock.now
        for _ in 0..<batchSize { operation() }
        let elapsed = ContinuousClock.now - start
        let (seconds, attoseconds) = elapsed.components
        samples.append((Double(seconds) * 1e9 + Double(attoseconds) / 1e9) / Double(batchSize))
    }
    return samples.sorted()[batches / 2]
}

@MainActor
func allocationsPerOperation(_ operation: () -> Void) -> Double {
    let iterations = 100_000
    for _ in 0..<1_000 { operation() }  // caches, lazy statics, first-call registration
    flight_allocations_begin()
    for _ in 0..<iterations { operation() }
    return Double(flight_allocations_end()) / Double(iterations)
}

var failures: [String] = []
let counting = flight_allocations_supported() != 0

// A counter that cannot tell "none" from "never ran" is worse than none:
// prove it sees an allocation before trusting it to see zero.
if counting {
    let seen = allocationsPerOperation { blackHole([Int](repeating: 1, count: 16)) }
    if seen < 1 {
        failures.append("the allocation counter saw \(seen)/op for an allocating closure; it is not counting")
    }
} else {
    print("warning: allocations cannot be counted on this platform; only latency is checked")
}

@MainActor
func run(_ scenario: Scenario) {
    let nanoseconds = max(
        0, nanosecondsPerOperation(scenario.operation) - nanosecondsPerOperation(scenario.baseline))
    let allocations = counting ? allocationsPerOperation(scenario.operation) : 0
    let latencyOK = nanoseconds <= scenario.latencyTarget
    let allocationsOK = allocations == 0
    print(
        scenario.name.padding(toLength: 40, withPad: " ", startingAt: 0),
        String(format: "%7.2f ns (≤ %4.0f)  %@", nanoseconds, scenario.latencyTarget, latencyOK ? "ok" : "SLOW"),
        counting ? String(format: "  %5.2f allocs  %@", allocations, allocationsOK ? "ok" : "ALLOCATES") : "")
    if !allocationsOK {
        failures.append("\(scenario.name): \(allocations) allocations per operation, target 0")
    }
    if !latencyOK, enforceLatency {
        failures.append("\(scenario.name): \(nanoseconds) ns, target ≤ \(scenario.latencyTarget) ns")
    }
}

var counter = 0
let increment = { counter &+= 1 }

run(
    Scenario(name: "emit, nothing attached", latencyTarget: 2, baseline: increment) {
        counter &+= 1
        Telemetry.emit(Nothing.self) { (.init(value: counter), .init(route: "/users/:id")) }
    })

run(
    Scenario(
        name: "span, nothing attached (overhead)", latencyTarget: 5,
        baseline: {
            counter &+= 1
            blackHole(counter)
        }
    ) {
        counter &+= 1
        blackHole(Telemetry.span(Load.self, metadata: .init(key: "k")) { _ in counter })
    })

// A narrow prefix must not cost unrelated telemetry anything: a log bridge
// on `flight.sessions` or a tracer on `flight.http` leaves every other event
// and span on the one-load path. (Before 0.35 the prefix set a global bit.)
do {
    let logger = try Telemetry.attach(prefix: "bench.elsewhere", id: "narrow") { _ in }
    let tracer = try Telemetry.observeSpans(prefix: "bench.elsewhere", id: "narrow", NoObserver())
    run(
        Scenario(name: "emit, unrelated to an attached prefix", latencyTarget: 2, baseline: increment) {
            counter &+= 1
            Telemetry.emit(Nothing.self) { (.init(value: counter), .init(route: "/users/:id")) }
        })
    run(
        Scenario(
            name: "span, unrelated to an observed prefix", latencyTarget: 5,
            baseline: {
                counter &+= 1
                blackHole(counter)
            }
        ) {
            counter &+= 1
            blackHole(Telemetry.span(Load.self, metadata: .init(key: "k")) { _ in counter })
        })
    logger.detach()
    tracer.detach()
}

do {
    let token = try Telemetry.attach(Typed.self, id: "bench") { _, _, _ in }
    run(
        Scenario(name: "emit, one typed no-op handler", latencyTarget: 40, baseline: increment) {
            counter &+= 1
            Telemetry.emit(Typed.self) { (.init(value: counter), .init(route: "/users/:id")) }
        })
    token.detach()
}

do {
    let token = try Telemetry.attach(prefix: "bench.erased", id: "bench") { _ in }
    run(
        Scenario(name: "emit, one erased no-op handler", latencyTarget: 80, baseline: increment) {
            counter &+= 1
            Telemetry.emit(Erased.self) { (.init(value: counter), .init(route: "/users/:id")) }
        })
    token.detach()
}

blackHole(counter)
if failures.isEmpty {
    print("all targets met")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
