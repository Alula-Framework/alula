import FlightTelemetry
import Foundation
import Synchronization

// Hand-written conformances, deliberately: every one of these is something
// `@TelemetryEvent` writes, and the core must work without it. Each test gets
// its own event types, because the registry is process-wide and swift-testing
// runs tests in parallel.

struct QueryMeasurements: TelemetryFields {
    var duration: Duration
    var rows: Int

    func encode(into encoder: inout FieldEncoder) {
        encoder.measurement("duration", duration)
        encoder.measurement("rows", rows)
    }

    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.duration: "duration"
        case \Self.rows: "rows"
        default: nil
        }
    }
}

struct QueryMetadata: TelemetryFields {
    var table: String
    var statement: String? = nil

    func encode(into encoder: inout FieldEncoder) {
        encoder.value("table", table)
        encoder.value("statement", statement)
    }

    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.table: "table"
        case \Self.statement: "statement"
        default: nil
        }
    }
}

enum QueryA: TelemetryEvent {
    typealias Measurements = QueryMeasurements
    typealias Metadata = QueryMetadata
    static let name: EventName = "test.query_a"
    static let _slot = HandlerSlot<QueryA>()
}

enum QueryB: TelemetryEvent {
    typealias Measurements = QueryMeasurements
    typealias Metadata = QueryMetadata
    static let name: EventName = "test.query_b"
    static let _slot = HandlerSlot<QueryB>()
}

enum PingA: TelemetryEvent {
    static let name: EventName = "test.ping_a"
    static let _slot = HandlerSlot<PingA>()
}
enum PingB: TelemetryEvent {
    static let name: EventName = "test.ping_b"
    static let _slot = HandlerSlot<PingB>()
}
enum PingC: TelemetryEvent {
    static let name: EventName = "test.ping_c"
    static let _slot = HandlerSlot<PingC>()
}
enum PingD: TelemetryEvent {
    static let name: EventName = "test.ping_d"
    static let _slot = HandlerSlot<PingD>()
}
enum PingE: TelemetryEvent {
    static let name: EventName = "test.ping_e"
    static let _slot = HandlerSlot<PingE>()
}
enum PingStress: TelemetryEvent {
    static let name: EventName = "test.stress"
    static let _slot = HandlerSlot<PingStress>()
}
enum ErasedOne: TelemetryEvent {
    typealias Measurements = QueryMeasurements
    typealias Metadata = QueryMetadata
    static let name: EventName = "erasedtest.db.query"
    static let _slot = HandlerSlot<ErasedOne>()
}
enum ErasedOther: TelemetryEvent {
    static let name: EventName = "erasedtest.dbx.query"
    static let _slot = HandlerSlot<ErasedOther>()
}

/// Two types claiming one name: whichever is touched first owns it.
enum ConflictOwner: TelemetryEvent {
    static let name: EventName = "test.conflict"
    static let _slot = HandlerSlot<ConflictOwner>()
}
enum ConflictImpostor: TelemetryEvent {
    static let name: EventName = "test.conflict"
    static let _slot = HandlerSlot<ConflictImpostor>()
}

enum ReclaimEvent: TelemetryEvent {
    static let name: EventName = "test.reclaim"
    static let _slot = HandlerSlot<ReclaimEvent>()
}

enum LateEvent: TelemetryEvent {
    static let name: EventName = "latetest.event"
    static let _slot = HandlerSlot<LateEvent>()
}

/// Flags shared between a test and the tasks it spawns.
final class RaceState: Sendable {
    let detached = Atomic<Bool>(false)
    let stop = Atomic<Bool>(false)
    let lateCalls = Atomic<Int>(0)
    let calls = Atomic<Int>(0)
}

/// Thread-safe collection a handler appends to.
final class Recorder<T: Sendable>: Sendable {
    private let items = Lock<[T]>([])
    func append(_ item: T) { items.withLock { $0.append(item) } }
    var all: [T] { items.withLock { $0 } }
    var count: Int { items.withLock { $0.count } }
}

// MARK: A span, by hand

struct LoadMetadata: TelemetryFields {
    var key: String
    func encode(into encoder: inout FieldEncoder) { encoder.value("key", key) }
    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        keyPath == \Self.key ? "key" : nil
    }
}

struct LoadStop: TelemetryFields {
    var hits: Int = 0
    func encode(into encoder: inout FieldEncoder) { encoder.value("hits", hits) }
    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        keyPath == \Self.hits ? "hits" : nil
    }
}

/// The flattened stop metadata `@TelemetrySpan` would generate.
struct LoadStopMetadata: TelemetryFields {
    var key: String
    var hits: Int
    func encode(into encoder: inout FieldEncoder) {
        encoder.value("key", key)
        encoder.value("hits", hits)
    }
    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.key: "key"
        case \Self.hits: "hits"
        default: nil
        }
    }
}

struct LoadExceptionMetadata: TelemetryFields {
    var key: String
    var errorType: String
    var hits: Int
    func encode(into encoder: inout FieldEncoder) {
        encoder.value("key", key)
        encoder.value("error_type", errorType)
        encoder.value("hits", hits)
    }
    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.key: "key"
        case \Self.errorType: "error_type"
        case \Self.hits: "hits"
        default: nil
        }
    }
}

enum Load: SpanEvent {
    typealias Metadata = LoadMetadata
    typealias StopMetadata = LoadStop
    static let name: EventName = "test.load"
    static let _spanFlags = SpanFlags(name: "test.load")

    enum Start: TelemetryEvent {
        typealias Measurements = SpanStartMeasurements
        typealias Metadata = LoadMetadata
        static let name: EventName = "test.load.start"
        static let _slot = HandlerSlot<Start>(span: Load._spanFlags, phase: .start)
    }
    enum Stop: TelemetryEvent {
        typealias Measurements = SpanDurationMeasurements
        typealias Metadata = LoadStopMetadata
        static let name: EventName = "test.load.stop"
        static let _slot = HandlerSlot<Stop>(span: Load._spanFlags, phase: .stop)
    }
    enum Exception: TelemetryEvent {
        typealias Measurements = SpanDurationMeasurements
        typealias Metadata = LoadExceptionMetadata
        static let name: EventName = "test.load.exception"
        static let _slot = HandlerSlot<Exception>(span: Load._spanFlags, phase: .exception)
    }

    static func initialStopMetadata() -> LoadStop { LoadStop() }
    static func stopMetadata(_ metadata: LoadMetadata, _ stop: LoadStop) -> LoadStopMetadata {
        LoadStopMetadata(key: metadata.key, hits: stop.hits)
    }
    static func exceptionMetadata(
        _ metadata: LoadMetadata, _ stop: LoadStop, errorType: String
    ) -> LoadExceptionMetadata {
        LoadExceptionMetadata(key: metadata.key, errorType: errorType, hits: stop.hits)
    }
}

final class Flag: Sendable {
    let value = Atomic<Bool>(false)
}

enum Environment {
    static func value(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }
}

/// Runs `body(index)` on `count` dedicated threads and waits for all of
/// them. For busy loops, which on Swift's cooperative pool would starve
/// every other suite running in the process.
func onThreads(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) async {
    let remaining = Counter(count)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        for index in 0..<count {
            Thread {
                body(index)
                if remaining.value.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
                    done.resume()
                }
            }.start()
        }
    }
}

final class Counter: Sendable {
    let value: Atomic<Int>
    init(_ value: Int) { self.value = Atomic(value) }
}
